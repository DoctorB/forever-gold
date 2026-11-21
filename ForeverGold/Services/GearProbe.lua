-- GearProbe: read-only check of the client functions an equipment-upgrade
-- finder would need (docs/STATUS.md, "Planned — equipment upgrades"). One
-- click, one pass in the same frame, bounded; nothing is bought, equipped or
-- requested from the AH. Saved in ForeverGoldDB.diagnostics.gear:
--   character  class, level, specialization answers, talent trees, skills
--   equipped   per slot: item string, slot type, level, stats
--   market     equippable item keys in the latest AH view, how long the
--              local slot lookup took, a sample with stats and usability
--   variants   random-suffix items: do two variants of one item give
--              different stats (stats read from the exact link)?
local _, ns = ...

local Schema = ns.Data.Schema
local GearProbe = {}
ns.Services.GearProbe = GearProbe

GearProbe.SLOTS = 19
GearProbe.MAX_SAMPLE = 24 -- market items read in full
GearProbe.MAX_VARIANT_ITEMS = 6 -- items with two variants compared
GearProbe.MAX_SKILLS = 40
-- Functions whose presence is reported (namespace or false, name).
GearProbe.SYMBOLS = {
  { false, "GetItemStats" }, { "C_Item", "GetItemStats" }, { false, "GetItemInfoInstant" },
  { "C_Item", "GetItemInfoInstant" }, { false, "GetInventoryItemLink" }, { false, "IsEquippableItem" },
  { "C_Item", "IsEquippableItem" }, { false, "IsUsableItem" }, { "C_Item", "IsUsableItem" },
  { "C_PlayerInfo", "CanUseItem" }, { false, "GetSpecialization" }, { false, "GetSpecializationInfo" },
  { "C_SpecializationInfo", "GetSpecialization" }, { false, "GetNumTalentTabs" }, { false, "GetTalentTabInfo" },
  { false, "GetPrimaryTalentTree" }, { false, "GetNumSkillLines" }, { false, "GetSkillLineInfo" },
  { "C_Item", "GetDetailedItemLevelInfo" }, { false, "GetItemSpell" },
}

-- deps: { client, opportunities, store, preciseMs?() }
function GearProbe.New(deps)
  return setmetatable(deps, { __index = GearProbe })
end

local function plain(client, value)
  if client:IsSecret(value) then return "secret" end
  return value
end

-- "STAMINA=8 STRENGTH=3" from a GetItemStats table (sorted, short names).
function GearProbe.StatsText(stats)
  if type(stats) ~= "table" then return nil end
  local parts = {}
  for key, value in pairs(stats) do
    local short = tostring(key):gsub("^ITEM_MOD_", ""):gsub("_SHORT$", "")
    parts[#parts + 1] = short .. "=" .. tostring(value)
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

local function itemString(link)
  return type(link) == "string" and (link:match("item:[%-%d:]+") or link) or nil
end

-- Answer of the first function that exists: value, "ns.name" | nil, "missing".
local function first(self, calls, ...)
  for _, call in ipairs(calls) do
    local ok, a, b, c, d, e, f, g = self.client:Call(call[1] or nil, call[2], ...)
    if ok then return { a, b, c, d, e, f, g }, (call[1] and (call[1] .. ".") or "") .. call[2] end
  end
  return nil, "missing"
end

function GearProbe:Stats(link)
  local answer, via = first(self, { { false, "GetItemStats" }, { "C_Item", "GetItemStats" } }, link)
  if not answer then return nil, via end
  return GearProbe.StatsText(answer[1]) or "none", via
end

-- itemID, type, subType, equipLoc, icon, classID, subclassID (local data).
function GearProbe:Instant(item)
  local answer = first(self, { { "C_Item", "GetItemInfoInstant" }, { false, "GetItemInfoInstant" } }, item)
  return answer
end

function GearProbe:Character()
  local c = self.client
  local out = {}
  local ok, className, classFile = c:Call(nil, "UnitClass", "player")
  if ok then out.class, out.classFile = plain(c, className), plain(c, classFile) end
  local okLevel, level = c:Call(nil, "UnitLevel", "player")
  if okLevel then out.level = plain(c, level) end
  local spec = first(self, { { false, "GetSpecialization" }, { "C_SpecializationInfo", "GetSpecialization" } })
  out.specialization = spec and tostring(spec[1]) or "missing"
  if spec and type(spec[1]) == "number" then
    local okInfo, id, name, _, _, role = c:Call(nil, "GetSpecializationInfo", spec[1])
    if okInfo then out.specInfo = string.format("%s %s %s", tostring(id), tostring(name), tostring(role)) end
  end
  local okPrimary, primary = c:Call(nil, "GetPrimaryTalentTree")
  if okPrimary then out.primaryTree = tostring(primary) end
  local okTabs, tabs = c:Call(nil, "GetNumTalentTabs")
  if okTabs and type(tabs) == "number" then
    out.trees = {}
    for tab = 1, math.min(tabs, 4) do
      -- Classic order: name, icon, points; some clients add id/description first.
      local okTab, a, b, cc, d, e, f = c:Call(nil, "GetTalentTabInfo", tab)
      if okTab then
        out.trees[tab] = table.concat({ tostring(a), tostring(b), tostring(cc), tostring(d), tostring(e), tostring(f) }, "|")
      end
    end
  end
  local okSkills, skills = c:Call(nil, "GetNumSkillLines")
  if okSkills and type(skills) == "number" then
    out.skills = {}
    for index = 1, math.min(skills, GearProbe.MAX_SKILLS) do
      local okLine, name, header, _, rank, _, _, maxRank = c:Call(nil, "GetSkillLineInfo", index)
      if okLine and not header then
        out.skills[#out.skills + 1] = string.format("%s %s/%s", tostring(name), tostring(rank), tostring(maxRank))
      end
    end
  end
  return out
end

function GearProbe:Equipped()
  local c = self.client
  local slots, read, withStats = {}, 0, 0
  for slot = 1, GearProbe.SLOTS do
    local ok, link = c:Call(nil, "GetInventoryItemLink", "player", slot)
    if ok and type(link) == "string" and not c:IsSecret(link) then
      read = read + 1
      local instant = self:Instant(link)
      local okInfo, _, _, _, itemLevel, minLevel = c:Call(nil, "GetItemInfo", link)
      local stats = self:Stats(link)
      if stats and stats ~= "none" then withStats = withStats + 1 end
      slots[#slots + 1] = {
        slot = slot, item = itemString(link), equipLoc = instant and instant[4], subType = instant and instant[3],
        itemLevel = okInfo and itemLevel or nil, minLevel = okInfo and minLevel or nil, stats = stats,
      }
    end
  end
  return slots, read, withStats
end

-- Equippable keys of the AH view (slot from local data only) and a sample.
function GearProbe:Market()
  local c = self.client
  local latest = self.opportunities and self.opportunities.latest or {}
  local preciseMs = self.preciseMs or function() return 0 end
  local started = preciseMs()
  local keys, equippable, byLoc, candidates = 0, 0, {}, {}
  local looked = {}
  for itemKey, view in pairs(latest) do
    keys = keys + 1
    local itemID = Schema.ItemIDOf(itemKey)
    local instant = itemID and looked[itemID]
    if itemID and instant == nil then
      instant = self:Instant(itemID) or false
      looked[itemID] = instant
    end
    local loc = instant and instant[4]
    if type(loc) == "string" and loc ~= "" and loc ~= "INVTYPE_BAG" and loc ~= "INVTYPE_NON_EQUIP_IGNORE" then
      equippable = equippable + 1
      byLoc[loc] = (byLoc[loc] or 0) + 1
      local listing = view.listings and view.listings[1]
      candidates[#candidates + 1] = { itemKey = itemKey, itemID = itemID, loc = loc,
        link = listing and listing.link or ("item:" .. itemID), variant = itemKey:find(":b", 1, true) ~= nil,
        price = listing and listing.buyoutTotal }
    end
  end
  local lookupMs = preciseMs() - started
  table.sort(candidates, function(a, b) return a.itemKey < b.itemKey end)
  -- Sample: variants first (their stats need the exact link), then plain.
  local sample, variants, plainCount = {}, 0, 0
  for _, candidate in ipairs(candidates) do
    if #sample >= GearProbe.MAX_SAMPLE then break end
    local take = candidate.variant and variants < GearProbe.MAX_SAMPLE / 2
      or (not candidate.variant and plainCount < GearProbe.MAX_SAMPLE / 2)
    if take then
      if candidate.variant then variants = variants + 1 else plainCount = plainCount + 1 end
      local link = candidate.link
      local okInfo, name, _, _, itemLevel, minLevel, _, subType, _, _, _, _, _, _, bindType = c:Call(nil, "GetItemInfo", link)
      local equippable1 = first(self, { { "C_Item", "IsEquippableItem" }, { false, "IsEquippableItem" } }, link)
      local usable = first(self, { { "C_Item", "IsUsableItem" }, { false, "IsUsableItem" } }, link)
      local canUse = first(self, { { "C_PlayerInfo", "CanUseItem" } }, candidate.itemID)
      sample[#sample + 1] = {
        itemKey = candidate.itemKey, loc = candidate.loc, item = itemString(link), price = candidate.price,
        name = okInfo and type(name) == "string" and name or nil, itemLevel = okInfo and itemLevel or nil,
        minLevel = okInfo and minLevel or nil, subType = okInfo and subType or nil, bind = okInfo and bindType or nil,
        stats = self:Stats(link), equippable = equippable1 and tostring(equippable1[1]) or "missing",
        usable = usable and tostring(usable[1]) or "missing", canUse = canUse and tostring(canUse[1]) or "missing",
      }
    end
  end
  return { keys = keys, equippable = equippable, byLoc = byLoc, lookupMs = lookupMs, sample = sample }, candidates
end

-- Random-suffix items with two variants listed: stats of each exact link.
function GearProbe:Variants(candidates)
  local byItem, order = {}, {}
  for _, candidate in ipairs(candidates) do
    if candidate.variant and candidate.link:find("item:", 1, true) then
      local list = byItem[candidate.itemID]
      if not list then
        list = {}
        byItem[candidate.itemID] = list
        order[#order + 1] = candidate.itemID
      end
      list[#list + 1] = candidate
    end
  end
  local out, differ, compared = {}, 0, 0
  for _, itemID in ipairs(order) do
    local list = byItem[itemID]
    if #list >= 2 and compared < GearProbe.MAX_VARIANT_ITEMS then
      compared = compared + 1
      local a, b = self:Stats(list[1].link), self:Stats(list[2].link)
      if a and b and a ~= b then differ = differ + 1 end
      out[#out + 1] = { itemID = itemID, a = itemString(list[1].link), statsA = a, b = itemString(list[2].link), statsB = b }
    end
  end
  return { compared = compared, differ = differ, items = out }
end

function GearProbe:Run(now)
  local report = { at = now, apis = {} }
  for _, symbol in ipairs(GearProbe.SYMBOLS) do
    local label = (symbol[1] and (symbol[1] .. ".") or "") .. symbol[2]
    report.apis[label] = self.client:Lookup(symbol[1] or nil, symbol[2]) ~= nil
  end
  report.character = self:Character()
  report.equipped, report.equippedRead, report.equippedStats = self:Equipped()
  local candidates
  report.market, candidates = self:Market()
  report.variants = self:Variants(candidates)
  if self.store then self.store.db.diagnostics.gear = report end
  return report
end

-- Lines for the window: the answers that decide the design.
function GearProbe.Summary(report, L)
  local lines = {}
  local ch = report.character or {}
  lines[#lines + 1] = string.format(L.GEAR_CHAR, tostring(ch.class), tostring(ch.level), tostring(ch.specialization),
    ch.trees and #ch.trees or 0, ch.skills and #ch.skills or 0)
  local missing = {}
  for label, present in pairs(report.apis or {}) do
    if not present then missing[#missing + 1] = label end
  end
  table.sort(missing)
  lines[#lines + 1] = string.format(L.GEAR_APIS, #missing == 0 and "-" or table.concat(missing, ", "))
  lines[#lines + 1] = string.format(L.GEAR_EQUIPPED, report.equippedRead or 0, report.equippedStats or 0)
  local m = report.market or {}
  local withStats = 0
  for _, s in ipairs(m.sample or {}) do if s.stats and s.stats ~= "none" then withStats = withStats + 1 end end
  lines[#lines + 1] = string.format(L.GEAR_MARKET, m.equippable or 0, m.keys or 0, m.lookupMs or 0,
    withStats, #(m.sample or {}))
  local v = report.variants or {}
  lines[#lines + 1] = string.format(L.GEAR_VARIANTS, v.differ or 0, v.compared or 0)
  lines[#lines + 1] = L.GEAR_SAVED
  return lines
end
