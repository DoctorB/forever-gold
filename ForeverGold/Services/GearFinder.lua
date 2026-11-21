-- GearFinder: equipment upgrades from the AH for the character's class and
-- talent tree (docs/STATUS.md, "Planned — equipment upgrades", step 1: a
-- read-only list). Nothing is bought, equipped or asked from the AH: the
-- candidates come from the latest AH view (the full scan already done).
--
-- Checked in game 2026-11-21 (Equipment test): only C_ functions exist; the
-- tree comes from C_Traits points; C_PlayerInfo.CanUseItem answers for
-- armour type, weapon skills, level and professions; most AH items have no
-- data yet, so candidates are filtered locally first (slot, class, price)
-- and their data asked for a batch at a time, cheapest first.
--
-- Bus: "gear.updated"(run)
local _, ns = ...

local Schema = ns.Data.Schema
local Gear = ns.Economy.Gear
local GearFinder = {}
ns.Services.GearFinder = GearFinder

GearFinder.BATCH = 150 -- items asked for per round
GearFinder.WAIT = 2 -- seconds between rounds (14 of 40 arrived within 2 s in game)
GearFinder.MAX_ROUNDS = 15
GearFinder.EQUIPPED_TRIES = 3
GearFinder.SHOWN = 12 -- results kept, best value first
-- Armour sub classes (Enum.ItemArmorSubclass) a class can ever wear:
-- 0 misc (rings, necks, trinkets), 1 cloth, 2 leather, 3 mail, 4 plate,
-- 6 shield. Level limits (mail/plate at 40) are left to CanUseItem.
GearFinder.ARMOR = {
  WARRIOR = { [0] = true, true, true, true, true, [6] = true },
  PALADIN = { [0] = true, true, true, true, true, [6] = true },
  HUNTER = { [0] = true, true, true, true },
  SHAMAN = { [0] = true, true, true, true, [6] = true },
  ROGUE = { [0] = true, true, true }, DRUID = { [0] = true, true, true },
  PRIEST = { [0] = true, true }, MAGE = { [0] = true, true }, WARLOCK = { [0] = true, true },
}
GearFinder.ARMOR_CLASS, GearFinder.WEAPON_CLASS = 4, 2

-- deps: { client, opportunities, store, scheduler, bus, clock, budgetMs?() }
function GearFinder.New(deps)
  return setmetatable(deps, { __index = GearFinder })
end

local function call(self, namespace, name, ...)
  return self.client:Call(namespace, name, ...)
end

function GearFinder:Instant(item)
  local ok, itemID, _, _, loc, _, classID, subclassID = call(self, "C_Item", "GetItemInfoInstant", item)
  if not ok then return nil end
  return itemID, loc, classID, subclassID
end

function GearFinder:Info(item)
  local ok, name, _, _, itemLevel, minLevel = call(self, "C_Item", "GetItemInfo", item)
  if not ok or type(name) ~= "string" then return nil end
  return { name = name, itemLevel = itemLevel, minLevel = minLevel }
end

function GearFinder:StatsOf(link)
  local ok, raw = call(self, "C_Item", "GetItemStats", link)
  return ok and Gear.Stats(raw) or nil
end

-- Talent tree with the most points ("protection"), from GearProbe's reads.
function GearFinder:Tree()
  local text = ns.Services.GearProbe.Trees(self)
  local best, most
  for slug, points in tostring(text):gmatch("([%a_]+)=(%d+)") do
    points = tonumber(points)
    if points > 0 and (not most or points > most) then best, most = slug, points end
  end
  return best
end

local function publish(self)
  if self.bus then self.bus:Publish("gear.updated", self.run) end
end

-- Starts a new search (the previous one stops). Returns the run.
function GearFinder:Start(reason)
  self.scheduler:Invalidate()
  local settings = self.store:Settings()
  local run = {
    at = self.clock(), reason = reason, state = "equipped", results = {}, best = {}, skipped = {},
    candidates = 0, evaluated = 0, asked = 0, rounds = 0,
    maxPrice = settings.gearMaxPrice, minGain = settings.gearMinGain,
  }
  self.run = run
  local okClass, _, classFile = call(self, nil, "UnitClass", "player")
  local okLevel, level = call(self, nil, "UnitLevel", "player")
  if not (okClass and type(classFile) == "string" and okLevel and type(level) == "number") then
    run.state = "no_character"
    publish(self)
    return run
  end
  run.class, run.level, run.tree = classFile, level, self:Tree()
  run.weights = ns.Data.GearWeights.For(classFile, run.tree)
  self:ReadEquipped(run, 1)
  return run
end

-- Worn items with their stats; items without data are asked for and read
-- again (in game even worn items had none at first).
function GearFinder:ReadEquipped(run, try)
  if self.run ~= run then return end
  local worn, missing = {}, 0
  for slot = 1, 19 do
    local ok, link = call(self, nil, "GetInventoryItemLink", "player", slot)
    if ok and type(link) == "string" and not self.client:IsSecret(link) then
      local itemID, loc = self:Instant(link)
      local stats = self:StatsOf(link)
      local info = self:Info(link)
      if not stats or not info then
        missing = missing + 1
        if itemID then call(self, "C_Item", "RequestLoadItemDataByID", itemID) end
      end
      worn[slot] = { link = link, itemID = itemID, loc = loc, stats = stats, name = info and info.name,
        score = Gear.Score(stats, run.weights) }
    end
  end
  run.worn = worn
  if missing > 0 and try < GearFinder.EQUIPPED_TRIES then
    self.scheduler:After(GearFinder.WAIT, function() self:ReadEquipped(run, try + 1) end)
    return
  end
  run.wornMissing = missing
  self:Collect(run)
end

-- Off-hand candidates of the kind worn now (shield, held item, weapon); no
-- two-hand weapon over a shield (the tank keeps it).
local function fitsHands(loc, worn)
  local off = worn[Gear.OFF_HAND]
  local offLoc = off and off.loc
  if loc == "INVTYPE_2HWEAPON" then return offLoc ~= "INVTYPE_SHIELD" end
  if loc == "INVTYPE_SHIELD" or loc == "INVTYPE_HOLDABLE" or loc == "INVTYPE_WEAPONOFFHAND" then
    return offLoc == loc
  end
  return true
end

-- Candidates from the AH view, spread over frames: slot known, armour the
-- class can wear, one unit, price under the cap; cheapest first.
function GearFinder:Collect(run)
  if self.run ~= run then return end
  run.state = "collecting"
  local latest = self.opportunities and self.opportunities.latest or {}
  local keys = {}
  for itemKey in pairs(latest) do keys[#keys + 1] = itemKey end
  local armor = GearFinder.ARMOR[run.class] or {}
  local list, looked = {}, {}
  self.scheduler:Chunk(1, #keys, self.budgetMs and self.budgetMs() or 8, function(index)
    local itemKey = keys[index]
    local itemID = Schema.ItemIDOf(itemKey)
    if not itemID then return end
    local seen = looked[itemID]
    if seen == nil then
      local _, loc, classID, subclassID = self:Instant(itemID)
      local ok = Gear.SLOTS[loc or ""] ~= nil and fitsHands(loc, run.worn)
        and (classID == GearFinder.WEAPON_CLASS or (classID == GearFinder.ARMOR_CLASS and armor[subclassID or -1]))
      seen = ok and loc or false
      looked[itemID] = seen
    end
    if not seen then return end
    local cheapest
    for _, listing in ipairs(latest[itemKey].listings or {}) do
      if listing.buyable and listing.quantity == 1 and listing.buyoutTotal
        and (not run.maxPrice or listing.buyoutTotal <= run.maxPrice)
        and (not cheapest or listing.buyoutTotal < cheapest.buyoutTotal) then
        cheapest = listing
      end
    end
    if cheapest then
      list[#list + 1] = { itemKey = itemKey, itemID = itemID, loc = seen, price = cheapest.buyoutTotal,
        link = cheapest.link or ("item:" .. itemID) }
    end
  end, function(done)
    if not done or self.run ~= run then return end
    table.sort(list, function(a, b)
      if a.price ~= b.price then return a.price < b.price end
      return a.itemKey < b.itemKey
    end)
    run.candidates = #list
    run.state = "checking"
    publish(self)
    self:Round(run, list)
  end)
end

local function skip(run, why) run.skipped[why] = (run.skipped[why] or 0) + 1 end

-- One candidate with its data: usable, at the level, better than worn.
function GearFinder:Evaluate(run, candidate, info)
  run.evaluated = run.evaluated + 1
  if type(info.minLevel) == "number" and info.minLevel > run.level then return skip(run, "level") end
  local okUse, canUse = call(self, "C_PlayerInfo", "CanUseItem", candidate.itemID)
  if okUse and canUse ~= true then return skip(run, "cannot_use") end
  local stats = self:StatsOf(candidate.link)
  if not stats then return skip(run, "no_stats") end
  local score = Gear.Score(stats, run.weights)
  local baseline, slots = Gear.Baseline(candidate.loc, run.worn)
  local gain = score - baseline
  if gain < (run.minGain or 0) then return skip(run, "no_gain") end
  local replaced = {}
  for _, slot in ipairs(slots) do if run.worn[slot] then replaced[#replaced + 1] = run.worn[slot] end end
  local result = {
    itemKey = candidate.itemKey, itemID = candidate.itemID, loc = candidate.loc, slot = slots[1], name = info.name,
    price = candidate.price, score = score, baseline = baseline, gain = gain,
    value = gain * 10000 / math.max(candidate.price, 1), -- gain per gold
    changes = Gear.Changes(stats, replaced, run.weights), replaces = replaced[1] and replaced[1].name,
  }
  -- One row per slot: the most gain per gold (the cheapest real upgrade).
  local group = tostring(slots[1])
  local kept = run.best[group]
  if not kept or result.value > kept.value or (result.value == kept.value and result.gain > kept.gain) then
    run.best[group] = result
  end
end

function GearFinder:Rank(run)
  local results = {}
  for _, result in pairs(run.best) do results[#results + 1] = result end
  table.sort(results, function(a, b)
    if a.value ~= b.value then return a.value > b.value end
    return a.itemKey < b.itemKey
  end)
  while #results > GearFinder.SHOWN do table.remove(results) end
  run.results = results
end

-- Reads every candidate whose data is there; asks for the next batch of
-- the others and comes back after WAIT seconds.
function GearFinder:Round(run, pending)
  if self.run ~= run then return end
  run.rounds = run.rounds + 1
  local missing = {}
  self.scheduler:Chunk(1, #pending, self.budgetMs and self.budgetMs() or 8, function(index)
    local candidate = pending[index]
    -- Asking GetItemInfo of an item without data sends a request to the
    -- server: thousands per round. The cache check asks for nothing.
    local okCached, isCached = call(self, "C_Item", "IsItemDataCachedByID", candidate.itemID)
    local info = not (okCached and isCached == false) and self:Info(candidate.link) or nil
    if info then self:Evaluate(run, candidate, info) else missing[#missing + 1] = candidate end
  end, function(done)
    if not done or self.run ~= run then return end
    self:Rank(run)
    run.waiting = #missing
    if #missing == 0 or run.rounds >= GearFinder.MAX_ROUNDS then
      run.state = "done"
      self:Save(run)
      publish(self)
      return
    end
    for index = 1, math.min(GearFinder.BATCH, #missing) do
      call(self, "C_Item", "RequestLoadItemDataByID", missing[index].itemID)
      run.asked = run.asked + 1
    end
    publish(self)
    self.scheduler:After(GearFinder.WAIT, function() self:Round(run, missing) end)
  end)
end

-- Summary for the analysis (ForeverGoldDB.diagnostics.gearFinder).
function GearFinder:Save(run)
  local db = self.store and self.store.db
  if not db then return end
  local rows = {}
  for index, r in ipairs(run.results) do
    rows[index] = string.format("%s %s %d g%.1f %s", tostring(r.loc), r.itemKey, r.price, r.gain, tostring(r.name))
  end
  db.diagnostics.gearFinder = {
    at = run.at, reason = run.reason, class = run.class, tree = run.tree, level = run.level,
    candidates = run.candidates, evaluated = run.evaluated, asked = run.asked, rounds = run.rounds,
    waiting = run.waiting, wornMissing = run.wornMissing, skipped = run.skipped, results = rows,
    finished = self.clock(),
  }
end
