-- Professions adapter (phase 4). Read-only observation of the open
-- profession window: which recipe APIs the client has and what they return.
-- Recipe discovery is not verified on this client: the Forever API
-- documentation (build 70790) lists C_TradeSkillUI.GetRecipeInfo and
-- GetRecipeSchematic but no GetAllRecipeIDs, and does not describe the
-- returned fields. Observe() therefore tries both the modern namespace and
-- the classic globals, and keeps the raw shape of what comes back (field
-- names and plain values) so that the recipe model is built on evidence.
-- Nothing here crafts, learns, opens or closes anything.
local _, ns = ...

local Professions = {}
ns.Compat.Professions = Professions

Professions.MAX_RECIPES = 12 -- recipes described in full per window
Professions.MAX_IDS = 300 -- recipe IDs kept per window
Professions.MAX_REAGENTS = 8
Professions.MAX_CATALOGUE = 1000 -- recipes read per window (Blacksmithing lists 507)

-- Presence only (never called unless listed in Observe below).
Professions.MODERN = {
  "GetAllRecipeIDs", "GetFilteredRecipeIDs", "GetRecipeInfo", "GetRecipeSchematic", "GetRecipeOutputItemData",
  "GetCraftableCount", "GetBaseProfessionInfo", "GetChildProfessionInfo", "GetProfessionSpells",
  "GetRecipeRequirements", "IsTradeSkillReady",
}
Professions.LEGACY = {
  "GetNumTradeSkills", "GetTradeSkillLine", "GetTradeSkillInfo", "GetTradeSkillItemLink", "GetTradeSkillRecipeLink",
  "GetTradeSkillNumMade", "GetTradeSkillNumReagents", "GetTradeSkillReagentInfo", "GetTradeSkillReagentItemLink",
  "GetTradeSkillCooldown", "GetTradeSkillTools", "GetProfessions", "GetProfessionInfo", "GetNumCrafts",
}

function Professions.New(client)
  return setmetatable({ client = client }, { __index = Professions })
end

function Professions:GetCapabilities()
  local c = self.client
  return {
    recipeInfo = c:Lookup("C_TradeSkillUI", "GetRecipeInfo") ~= nil,
    recipeSchematic = c:Lookup("C_TradeSkillUI", "GetRecipeSchematic") ~= nil,
    observed = false,
  }
end

-- Plain copy of a client value: numbers, booleans and short strings as they
-- are, tables down to `depth` levels with at most `width` keys each, any
-- other value by its type name. Secret values are never copied.
function Professions.Capture(client, value, depth, width)
  if client and client:IsSecret(value) then return "secret" end
  local kind = type(value)
  if kind == "number" or kind == "boolean" then return value end
  if kind == "string" then return #value <= 120 and value or value:sub(1, 120) end
  if kind ~= "table" then return kind end
  if depth <= 0 then return "table" end
  local out, count = {}, 0
  for key, item in pairs(value) do
    local keyKind = type(key)
    if keyKind == "string" or keyKind == "number" then
      count = count + 1
      if count > width then
        out._truncated = true
        break
      end
      out[key] = Professions.Capture(client, item, depth - 1, width)
    end
  end
  return out
end

-- Result of a protected call as a plain value or "error: ...".
local function first(self, depth, ok, value)
  if not ok then return "error: " .. tostring(value):sub(1, 100) end
  return Professions.Capture(self.client, value, depth, 40)
end

-- Compact recipe from GetRecipeInfo + GetRecipeSchematic, in the shape of
-- Data/Recipes; nil when the schematic has no output or unreadable reagents.
-- Field names verified in game on build 70862 (2026-11-07, API-AUDIT row 24).
function Professions.Compact(info, schematic, profession)
  if type(info) ~= "table" or type(schematic) ~= "table" then return nil end
  local output, low, high = schematic.outputItemID, schematic.quantityMin, schematic.quantityMax
  if type(output) ~= "number" or output <= 0 or type(low) ~= "number" or low <= 0 then return nil end
  local reagents = {}
  for _, slot in ipairs(type(schematic.reagentSlotSchematics) == "table" and schematic.reagentSlotSchematics or {}) do
    if slot.required ~= false then
      local reagent = type(slot.reagents) == "table" and slot.reagents[1]
      local itemID = type(reagent) == "table" and reagent.itemID
      if type(itemID) ~= "number" or type(slot.quantityRequired) ~= "number" then return nil end
      reagents[#reagents + 1] = { itemID = itemID, quantity = slot.quantityRequired }
    end
  end
  if #reagents == 0 then return nil end
  return {
    id = info.recipeID or schematic.recipeID, name = info.name or schematic.name, profession = profession,
    learned = info.learned == true, difficulty = info.relativeDifficulty,
    -- Skill where the recipe turns grey: an upper bound of the skill it
    -- requires (the recipe window gives no requirement; the trainer does).
    trivial = type(info.maxTrivialLevel) == "number" and info.maxTrivialLevel or nil,
    outputs = { { itemID = output, quantity = low } }, quantityMax = high,
    reagents = reagents,
  }
end

local function observeModern(self, report, profession)
  local c = self.client
  local ids
  for _, name in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
    if c:Lookup("C_TradeSkillUI", name) then
      local ok, list = c:Call("C_TradeSkillUI", name)
      if ok and type(list) == "table" then
        report[name] = #list
        if not ids and #list > 0 then ids, report.idSource = list, name end
      else
        report[name] = ok and type(list) or ("error: " .. tostring(list):sub(1, 100))
      end
    end
  end
  if not ids then return end
  report.recipeIDs = {}
  for index = 1, math.min(#ids, Professions.MAX_IDS) do report.recipeIDs[index] = ids[index] end
  -- Whole catalogue (learned or not) in compact form; the raw shape is kept
  -- for the first recipes, learned ones first.
  local catalogue, learned, other, unreadable = {}, {}, {}, 0
  for index = 1, math.min(#ids, Professions.MAX_CATALOGUE) do
    local id = ids[index]
    local okInfo, info = c:Call("C_TradeSkillUI", "GetRecipeInfo", id)
    local okSchematic, schematic = c:Call("C_TradeSkillUI", "GetRecipeSchematic", id, false)
    local recipe = okInfo and okSchematic and Professions.Compact(info, schematic, profession)
    if recipe then
      catalogue[#catalogue + 1] = recipe
    else
      unreadable = unreadable + 1
    end
    local list = (okInfo and type(info) == "table" and info.learned == true) and learned or other
    list[#list + 1] = { id = id, info = info, schematic = schematic, okInfo = okInfo, okSchematic = okSchematic }
  end
  report.catalogueSize, report.unreadable, report.learned = #catalogue, unreadable, #learned
  report.recipes = {}
  for _, list in ipairs({ learned, other }) do
    for _, raw in ipairs(list) do
      if #report.recipes >= Professions.MAX_RECIPES then break end
      local entry = { id = raw.id }
      entry.info = first(self, 2, raw.okInfo, raw.info)
      -- schematic > reagentSlotSchematics > slot > reagents > reagent > fields
      entry.schematic = first(self, 6, raw.okSchematic, raw.schematic)
      if c:Lookup("C_TradeSkillUI", "GetCraftableCount") then
        entry.craftable = first(self, 0, c:Call("C_TradeSkillUI", "GetCraftableCount", raw.id))
      end
      report.recipes[#report.recipes + 1] = entry
    end
  end
  return catalogue
end

local function short(value)
  if type(value) == "string" then return value:sub(1, 120) end
  if type(value) == "number" or type(value) == "boolean" then return value end
  return nil
end

local function observeLegacy(self, report)
  local c = self.client
  local okLine, name, rank, maxRank = c:Call(nil, "GetTradeSkillLine")
  if okLine then report.line = { name = short(name), rank = short(rank), max = short(maxRank) } end
  local okCount, count = c:Call(nil, "GetNumTradeSkills")
  if not okCount then return end
  report.count = short(count)
  if type(count) ~= "number" then return end
  report.recipes = {}
  local headers = 0
  for index = 1, count do
    local ok, recipeName, kind, available = c:Call(nil, "GetTradeSkillInfo", index)
    if ok and (kind == "header" or kind == "subheader") then
      headers = headers + 1
    elseif ok and #report.recipes < Professions.MAX_RECIPES then
      local entry = { index = index, name = short(recipeName), kind = short(kind), available = short(available) }
      entry.link = short(select(2, c:Call(nil, "GetTradeSkillItemLink", index)))
      entry.recipeLink = short(select(2, c:Call(nil, "GetTradeSkillRecipeLink", index)))
      local okMade, low, high = c:Call(nil, "GetTradeSkillNumMade", index)
      if okMade then entry.madeMin, entry.madeMax = short(low), short(high) end
      local okReagents, reagents = c:Call(nil, "GetTradeSkillNumReagents", index)
      entry.reagentCount = okReagents and short(reagents) or nil
      if okReagents and type(reagents) == "number" then
        entry.reagents = {}
        for slot = 1, math.min(reagents, Professions.MAX_REAGENTS) do
          local okInfo, reagentName, _, needed, owned = c:Call(nil, "GetTradeSkillReagentInfo", index, slot)
          entry.reagents[slot] = {
            name = okInfo and short(reagentName) or nil, count = okInfo and short(needed) or nil,
            have = okInfo and short(owned) or nil,
            link = short(select(2, c:Call(nil, "GetTradeSkillReagentItemLink", index, slot))),
          }
        end
      end
      local okCooldown, cooldown = c:Call(nil, "GetTradeSkillCooldown", index)
      if okCooldown and cooldown then entry.cooldown = short(cooldown) end
      report.recipes[#report.recipes + 1] = entry
    end
  end
  report.headers = headers
end

-- Name of the open profession window, or nil when none is open. With the
-- window closed the client still answers, with an empty profession name
-- (seen in game on build 70862) and the last window's recipes.
function Professions:OpenProfession()
  local c = self.client
  local ok, base = c:Call("C_TradeSkillUI", "GetBaseProfessionInfo")
  if ok and type(base) == "table" and type(base.professionName) == "string" and base.professionName ~= "" then
    return base.professionName, base
  end
  local okLine, name = c:Call(nil, "GetTradeSkillLine")
  if okLine and type(name) == "string" and name ~= "" and name ~= "UNKNOWN" then return name, nil end
  return nil
end

-- Everything the open profession window exposes, read-only.
-- Returns report, catalogue (compact recipes) or nil, "no_window".
-- report: { name, skill, maxSkill, modern = {...}, legacy = {...}, symbols = { [name] = bool } }.
function Professions:Observe()
  local c = self.client
  local name, base = self:OpenProfession()
  if not name then return nil, "no_window" end
  local report = { name = name, symbols = {}, modern = {}, legacy = {} }
  for _, symbol in ipairs(Professions.MODERN) do
    report.symbols["C_TradeSkillUI." .. symbol] = c:Lookup("C_TradeSkillUI", symbol) ~= nil
  end
  for _, symbol in ipairs(Professions.LEGACY) do report.symbols[symbol] = c:Lookup(nil, symbol) ~= nil end
  if base then
    report.modern.base = Professions.Capture(c, base, 2, 40)
    report.skill, report.maxSkill = base.skillLevel, base.maxSkillLevel
  end
  if c:Lookup("C_TradeSkillUI", "GetChildProfessionInfo") then
    report.modern.child = first(self, 2, c:Call("C_TradeSkillUI", "GetChildProfessionInfo"))
  end
  local catalogue = observeModern(self, report.modern, name)
  observeLegacy(self, report.legacy)
  if report.legacy.line then
    report.skill = report.skill or report.legacy.line.rank
    report.maxSkill = report.maxSkill or report.legacy.line.max
  end
  return report, catalogue or {}
end
