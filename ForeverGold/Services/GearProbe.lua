-- GearProbe: read-only check of the client functions an equipment-upgrade
-- finder would need (docs/STATUS.md, "Planned — equipment upgrades"). One
-- click: a first pass in the same frame, then items without data are asked
-- for and read again after RELOAD_WAIT seconds. Nothing is bought, equipped
-- or requested from the AH. Saved in ForeverGoldDB.diagnostics.gear:
--   character  class, level, specialization answer, points per talent tree
--              (C_Traits, as Forever One Button reads them)
--   equipped   per slot: item string, slot type, level, stats, usability
--   market     equippable item keys of the latest AH view and a sample
--              spread over item kinds, at or above the character's level
--   variants   random-suffix items: stats of two variants from their links
-- First run 2026-11-21 10:14 (Warrior 25): only the C_ functions exist,
-- GetSpecialization answers 1, stats differ per variant (5 of 6).
local _, ns = ...

local Schema = ns.Data.Schema
local GearProbe = {}
ns.Services.GearProbe = GearProbe

GearProbe.SLOTS = 19
GearProbe.MAX_SAMPLE = 36 -- market items read in full
GearProbe.PER_BUCKET = 2 -- per item kind (sub type) and level side
GearProbe.MAX_VARIANT_ITEMS = 6 -- items with two variants compared
GearProbe.MAX_LOADS = 40 -- items without data asked for
GearProbe.RELOAD_WAIT = 2
-- Functions whose presence is reported (namespace or false, name).
GearProbe.SYMBOLS = {
  { "C_Item", "GetItemStats" }, { "C_Item", "GetItemInfo" }, { "C_Item", "GetItemInfoInstant" },
  { "C_Item", "IsEquippableItem" }, { "C_Item", "IsUsableItem" }, { "C_PlayerInfo", "CanUseItem" },
  { "C_Item", "RequestLoadItemDataByID" }, { "C_Item", "IsItemDataCachedByID" }, { false, "GetInventoryItemLink" },
  { "C_SpecializationInfo", "GetSpecialization" }, { "C_SpecializationInfo", "GetSpecializationInfo" },
  { "C_ClassTalents", "GetActiveConfigID" }, { "C_ClassTalents", "GetTraitTreeForSpec" },
  { "C_Traits", "GetGroupDisplayInfoByTreeID" }, { "C_Traits", "GetGroupCurrencyInfo" },
  { "C_Item", "GetDetailedItemLevelInfo" }, { "C_Item", "GetItemSpell" },
}

-- deps: { client, opportunities, store, preciseMs?(), after?(delay, fn) }
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

-- Answer of the first function that exists: { results }, "ns.name" | nil, "missing".
local function first(self, calls, ...)
  for _, call in ipairs(calls) do
    local ok, a, b, c, d, e, f, g, h, i, j, k, l, m, n = self.client:Call(call[1] or nil, call[2], ...)
    if ok then return { a, b, c, d, e, f, g, h, i, j, k, l, m, n }, (call[1] and (call[1] .. ".") or "") .. call[2] end
  end
  return nil, "missing"
end

function GearProbe:Stats(link)
  local answer, via = first(self, { { "C_Item", "GetItemStats" }, { false, "GetItemStats" } }, link)
  if not answer then return nil, via end
  return GearProbe.StatsText(answer[1]) or "none", via
end

-- itemID, type, subType, equipLoc, icon, classID, subclassID (local data).
function GearProbe:Instant(item)
  return first(self, { { "C_Item", "GetItemInfoInstant" }, { false, "GetItemInfoInstant" } }, item)
end

-- { name, itemLevel, minLevel, subType, bindType } or nil when not loaded.
function GearProbe:Info(item)
  local a = first(self, { { "C_Item", "GetItemInfo" }, { false, "GetItemInfo" } }, item)
  if not a or type(a[1]) ~= "string" then return nil end
  return { name = a[1], itemLevel = a[4], minLevel = a[5], subType = a[7], bindType = a[14] }
end

function GearProbe:Usable(item, itemID)
  local usable = first(self, { { "C_Item", "IsUsableItem" }, { false, "IsUsableItem" } }, item)
  local canUse = first(self, { { "C_PlayerInfo", "CanUseItem" } }, itemID)
  local equippable = first(self, { { "C_Item", "IsEquippableItem" }, { false, "IsEquippableItem" } }, item)
  return usable and tostring(usable[1]) or "missing", canUse and tostring(canUse[1]) or "missing",
    equippable and tostring(equippable[1]) or "missing"
end

local function slug(name)
  if type(name) ~= "string" then return tostring(name) end
  return (name:lower():gsub("[^%a]+", "_"):gsub("^_+", ""):gsub("_+$", ""))
end

-- Points per talent tree, the reads Forever One Button makes (in game since
-- 1.1.x): "arms=0 fury=0 protection=24", or the step that failed.
function GearProbe:Trees()
  local c = self.client
  local okConfig, configID = c:Call("C_ClassTalents", "GetActiveConfigID")
  local okSpec, spec = c:Call("C_SpecializationInfo", "GetSpecialization")
  if not (okConfig and okSpec) then return "missing" end
  local okInfo, specID = c:Call("C_SpecializationInfo", "GetSpecializationInfo", spec)
  local okTree, treeID = c:Call("C_ClassTalents", "GetTraitTreeForSpec", okInfo and specID or nil)
  if not (okTree and treeID and configID) then
    return string.format("no tree (config %s spec %s specID %s)", tostring(configID), tostring(spec), tostring(specID))
  end
  local okDisplay, displays = c:Call("C_Traits", "GetGroupDisplayInfoByTreeID", treeID)
  if not okDisplay or type(displays) ~= "table" then return "no groups" end
  local ids, names = {}, {}
  for index, display in ipairs(displays) do
    ids[index] = display.groupID
    names[display.groupID] = slug(display.displayName)
  end
  local okCurrency, infos = c:Call("C_Traits", "GetGroupCurrencyInfo", configID, ids)
  if not okCurrency or type(infos) ~= "table" then return "no points" end
  local parts = {}
  for _, info in ipairs(infos) do
    local currency = info.currencyInfos and info.currencyInfos[1]
    local n = currency and (currency.spentInTree or currency.spent)
    parts[#parts + 1] = tostring(names[info.traitNodeGroupID]) .. "=" .. tostring(n)
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

function GearProbe:Character()
  local c = self.client
  local out = {}
  local ok, className, classFile = c:Call(nil, "UnitClass", "player")
  if ok then out.class, out.classFile = plain(c, className), plain(c, classFile) end
  local okLevel, level = c:Call(nil, "UnitLevel", "player")
  if okLevel then out.level = plain(c, level) end
  local spec = first(self, { { "C_SpecializationInfo", "GetSpecialization" }, { false, "GetSpecialization" } })
  out.specialization = spec and tostring(spec[1]) or "missing"
  out.trees = self:Trees()
  return out
end

function GearProbe:Equipped()
  local c = self.client
  local slots, read, withStats, usableCount = {}, 0, 0, 0
  for slot = 1, GearProbe.SLOTS do
    local ok, link = c:Call(nil, "GetInventoryItemLink", "player", slot)
    if ok and type(link) == "string" and not c:IsSecret(link) then
      read = read + 1
      local instant = self:Instant(link)
      local itemID = instant and instant[1]
      local info = self:Info(link)
      local stats = self:Stats(link)
      if stats and stats ~= "none" then withStats = withStats + 1 end
      local usable, canUse, equippable = self:Usable(link, itemID)
      if usable == "true" or canUse == "true" then usableCount = usableCount + 1 end
      slots[#slots + 1] = {
        slot = slot, item = itemString(link), link = link, itemID = itemID, equipLoc = instant and instant[4],
        subType = instant and instant[3], itemLevel = info and info.itemLevel, minLevel = info and info.minLevel,
        stats = stats, usable = usable, canUse = canUse, equippable = equippable,
      }
    end
  end
  return slots, read, withStats, usableCount
end

local function equipLoc(loc)
  return type(loc) == "string" and loc ~= "" and loc ~= "INVTYPE_BAG" and loc ~= "INVTYPE_NON_EQUIP_IGNORE"
    and loc ~= "INVTYPE_AMMO" and loc ~= "INVTYPE_TABARD" and loc ~= "INVTYPE_BODY"
end

-- Equippable keys of the AH view and a sample spread over item kinds
-- (sub type: Mail, Plate, Wands, Daggers...) and over the level side
-- (required level at most the character's, or above).
function GearProbe:Market(level)
  local latest = self.opportunities and self.opportunities.latest or {}
  local preciseMs = self.preciseMs or function() return 0 end
  local started = preciseMs()
  local keys, equippable, byLoc, candidates, looked = 0, 0, {}, {}, {}
  for itemKey, view in pairs(latest) do
    keys = keys + 1
    local itemID = Schema.ItemIDOf(itemKey)
    local instant = itemID and looked[itemID]
    if itemID and instant == nil then
      instant = self:Instant(itemID) or false
      looked[itemID] = instant
    end
    local loc = instant and instant[4]
    if equipLoc(loc) then
      equippable = equippable + 1
      byLoc[loc] = (byLoc[loc] or 0) + 1
      local listing = view.listings and view.listings[1]
      candidates[#candidates + 1] = { itemKey = itemKey, itemID = itemID, loc = loc, subType = instant[3],
        link = listing and listing.link or ("item:" .. itemID), variant = itemKey:find(":b", 1, true) ~= nil,
        price = listing and listing.buyoutTotal }
    end
  end
  local lookupMs = preciseMs() - started
  table.sort(candidates, function(a, b) return a.itemKey < b.itemKey end)
  started = preciseMs()
  local buckets, sample, notLoaded, loadIDs, loadSeen = {}, {}, 0, {}, {}
  for _, candidate in ipairs(candidates) do
    local info = self:Info(candidate.link)
    if not info then
      notLoaded = notLoaded + 1
      if #loadIDs < GearProbe.MAX_LOADS and not loadSeen[candidate.itemID] then
        loadSeen[candidate.itemID] = true
        loadIDs[#loadIDs + 1] = candidate.itemID
      end
    elseif #sample < GearProbe.MAX_SAMPLE then
      local fits = type(info.minLevel) == "number" and type(level) == "number" and info.minLevel <= level
      local bucket = tostring(info.subType) .. (fits and "<=" or ">")
      local taken = buckets[bucket] or 0
      if taken < GearProbe.PER_BUCKET then
        buckets[bucket] = taken + 1
        local usable, canUse, equippable1 = self:Usable(candidate.link, candidate.itemID)
        sample[#sample + 1] = {
          itemKey = candidate.itemKey, loc = candidate.loc, item = itemString(candidate.link), link = candidate.link,
          itemID = candidate.itemID, price = candidate.price, name = info.name, itemLevel = info.itemLevel,
          minLevel = info.minLevel, subType = info.subType, bind = info.bindType, fits = fits,
          stats = self:Stats(candidate.link), usable = usable, canUse = canUse, equippable = equippable1,
        }
      end
    end
  end
  return { keys = keys, equippable = equippable, byLoc = byLoc, lookupMs = lookupMs, infoMs = preciseMs() - started,
    notLoaded = notLoaded, sample = sample }, candidates, loadIDs
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

-- Items without data: ask for them, read again after the wait (sample and
-- equipped rows without stats, plus the asked items' slot info).
function GearProbe:Reload(report, loadIDs, done)
  local asked = 0
  for _, itemID in ipairs(loadIDs) do
    if self.client:Call("C_Item", "RequestLoadItemDataByID", itemID) then asked = asked + 1 end
  end
  for _, row in ipairs(report.equipped) do
    if row.stats == "none" and row.itemID then self.client:Call("C_Item", "RequestLoadItemDataByID", row.itemID) end
  end
  report.reload = { asked = asked }
  local function finish()
    -- Item strings are kept; full links only served the reads.
    for _, row in ipairs(report.equipped) do row.link = nil end
    for _, row in ipairs(report.market.sample) do row.link = nil end
    if done then done(report) end
  end
  if not self.after then
    finish()
    return
  end
  self.after(GearProbe.RELOAD_WAIT, function()
    local loaded, stats = 0, 0
    for _, itemID in ipairs(loadIDs) do
      local info = self:Info(itemID)
      if info then
        loaded = loaded + 1
        local s = self:Stats("item:" .. itemID)
        if s and s ~= "none" then stats = stats + 1 end
      end
    end
    local equippedNow = 0
    for _, row in ipairs(report.equipped) do
      if row.stats == "none" then
        row.statsLater = self:Stats(row.link)
        if row.statsLater and row.statsLater ~= "none" then equippedNow = equippedNow + 1 end
      end
    end
    report.reload.loaded, report.reload.withStats, report.reload.equippedNow = loaded, stats, equippedNow
    finish()
  end)
end

-- done(report): after the re-read (or at once without a timer).
function GearProbe:Run(now, done)
  local report = { at = now, apis = {}, round = 2 }
  for _, symbol in ipairs(GearProbe.SYMBOLS) do
    local label = (symbol[1] and (symbol[1] .. ".") or "") .. symbol[2]
    report.apis[label] = self.client:Lookup(symbol[1] or nil, symbol[2]) ~= nil
  end
  report.character = self:Character()
  report.equipped, report.equippedRead, report.equippedStats, report.equippedUsable = self:Equipped()
  local candidates, loadIDs
  report.market, candidates, loadIDs = self:Market(report.character.level)
  report.variants = self:Variants(candidates)
  if self.store then self.store.db.diagnostics.gear = report end
  self:Reload(report, loadIDs, done)
  return report
end

-- Lines for the window: the answers that decide the design.
function GearProbe.Summary(report, L)
  local lines = {}
  local ch = report.character or {}
  lines[#lines + 1] = string.format(L.GEAR_CHAR, tostring(ch.class), tostring(ch.level), tostring(ch.trees))
  local missing = {}
  for label, present in pairs(report.apis or {}) do
    if not present then missing[#missing + 1] = label end
  end
  table.sort(missing)
  lines[#lines + 1] = string.format(L.GEAR_APIS, #missing == 0 and "-" or table.concat(missing, ", "))
  lines[#lines + 1] = string.format(L.GEAR_EQUIPPED, report.equippedRead or 0, report.equippedStats or 0,
    report.equippedUsable or 0)
  local m = report.market or {}
  local fitsUsable, fits, aboveUsable, above = 0, 0, 0, 0
  for _, s in ipairs(m.sample or {}) do
    local yes = s.usable == "true" or s.canUse == "true"
    if s.fits then
      fits = fits + 1
      if yes then fitsUsable = fitsUsable + 1 end
    else
      above = above + 1
      if yes then aboveUsable = aboveUsable + 1 end
    end
  end
  lines[#lines + 1] = string.format(L.GEAR_MARKET, m.equippable or 0, m.keys or 0, m.notLoaded or 0)
  lines[#lines + 1] = string.format(L.GEAR_USABLE, fitsUsable, fits, aboveUsable, above)
  local v = report.variants or {}
  lines[#lines + 1] = string.format(L.GEAR_VARIANTS, v.differ or 0, v.compared or 0)
  local r = report.reload
  if r and r.loaded then
    lines[#lines + 1] = string.format(L.GEAR_RELOAD, r.loaded, r.asked or 0, r.withStats or 0)
  elseif r then
    lines[#lines + 1] = string.format(L.GEAR_RELOADING, r.asked or 0)
  end
  lines[#lines + 1] = L.GEAR_SAVED
  return lines
end
