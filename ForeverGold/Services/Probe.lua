-- Probe: read-only AH investigation started by the user ("AH search test").
-- It runs a few searches and browses, one at a time and only when the AH is
-- ready, and records what the server answers in ForeverGoldDB.diagnostics.probe:
--   variants  items with bonus IDs: direct search with the built key, then a
--             browse by name and a search with each server key of the item;
--   lots      non-commodity items sold in lots of 2+: replicate lot vs the
--             item-search row, to learn whether buyoutAmount is per lot or
--             per unit (votes "total" / "unit").
-- Nothing is bought, bid, posted or cancelled.
local _, ns = ...

local Schema = ns.Data.Schema
local Probe = {}
ns.Services.Probe = Probe

Probe.MAX_VARIANTS = 4
Probe.MAX_LOTS = 4
Probe.READY_TRIES = 15
Probe.STEP_TIMEOUT = 12

-- deps: { scanner, ah, client, items, opportunities, scheduler, clock, store, printer?(text) }
function Probe.New(deps)
  return setmetatable(deps, { __index = Probe })
end

local function keyText(key)
  return string.format("%s/%s/%s", tostring(key.itemLevel), tostring(key.itemSuffix), tostring(key.battlePetSpeciesID))
end

local function rowsText(listings, limit)
  local parts = {}
  for index = 1, math.min(#listings, limit or 6) do
    local l = listings[index]
    parts[#parts + 1] = string.format("%dx%s", l.quantity, tostring(l.buyoutTotal))
  end
  return table.concat(parts, " ")
end

-- Candidates from the latest replicate view. Pure apart from the lookups.
function Probe:Candidates()
  local variants, lots, seenV, seenL = {}, {}, {}, {}
  for itemKey, view in pairs(self.opportunities.latest or {}) do
    local itemID = Schema.ItemIDOf(itemKey)
    local info = itemID and self.items and self.items:Read(itemID)
    for _, listing in ipairs(view.listings or {}) do
      if listing.source == "replicate" and info and info.name then
        if listing.link and itemKey:find(":b", 1, true) and not seenV[itemID] and #variants < Probe.MAX_VARIANTS then
          seenV[itemID] = true
          variants[#variants + 1] = { itemID = itemID, itemKey = itemKey, name = info.name, link = listing.link,
            quantity = listing.quantity, buyout = listing.buyoutTotal }
        end
        if listing.quantity > 1 and listing.buyoutTotal and not listing.divisible and not seenL[itemID]
          and #lots < Probe.MAX_LOTS and self.ah:IsCommodity(itemID) == false then
          seenL[itemID] = true
          local replicate = {}
          for _, other in ipairs(view.listings) do
            if other.buyoutTotal then replicate[#replicate + 1] = { quantity = other.quantity, total = other.buyoutTotal } end
          end
          lots[#lots + 1] = { itemID = itemID, itemKey = itemKey, name = info.name, link = listing.link, replicate = replicate }
        end
      end
    end
  end
  return variants, lots
end

-- Runs fn when the scanner is idle and the AH ready; gives up after a while.
function Probe:WhenReady(fn, tries)
  tries = tries or 0
  if not self.running then return end
  if self.ah:IsReady() == false or self.scanner:IsActive() then
    if tries >= Probe.READY_TRIES then
      self:Log({ kind = "skip", reason = "throttled" })
      self:Next()
      return
    end
    self.scheduler:After(1, function() self:WhenReady(fn, tries + 1) end)
    return
  end
  fn()
end

function Probe:Log(entry)
  entry.t = self.clock()
  local results = self.report.results
  results[#results + 1] = entry
end

-- A search step with its own timeout; done(listings or nil).
function Probe:Search(itemID, suffix, level, key, done)
  self.step = (self.step or 0) + 1
  local step, finished = self.step, false
  local ok = self.scanner:Search(itemID, suffix, function(_, listings)
    if finished or self.step ~= step then return end
    finished = true
    done(listings)
  end, level, key)
  if not ok then
    finished = true
    done(nil)
    return
  end
  self.scheduler:After(Probe.STEP_TIMEOUT, function()
    if not finished and self.step == step then
      finished = true
      done(nil)
    end
  end)
end

function Probe:Browse(name, done)
  self.step = (self.step or 0) + 1
  local step, finished = self.step, false
  local ok = self.scanner:Browse(name, function(results)
    if finished or self.step ~= step then return end
    finished = true
    done(results)
  end)
  if not ok then
    finished = true
    done(nil)
    return
  end
  self.scheduler:After(Probe.STEP_TIMEOUT, function()
    if not finished and self.step == step then
      finished = true
      done(nil)
    end
  end)
end

-- Variant item: built key, then browse and the server keys (at most 3).
function Probe:RunVariant(c)
  local level = self.client:ItemLevel(c.link)
  self:WhenReady(function()
    self:Search(c.itemID, Schema.SuffixOf(c.itemKey), level, nil, function(listings)
      self:Log({ kind = "variant_direct", itemID = c.itemID, name = c.name, itemKey = c.itemKey, level = level,
        replicate = string.format("%dx%s", c.quantity, tostring(c.buyout)),
        rows = listings and #listings or "no_answer", sample = listings and rowsText(listings) or nil })
      self:WhenReady(function()
        self:Browse(c.name, function(results)
          local keys = {}
          for _, result in ipairs(results or {}) do
            if result.itemKey.itemID == c.itemID then keys[#keys + 1] = result.itemKey end
          end
          local texts = {}
          for index, key in ipairs(keys) do texts[index] = keyText(key) end
          self:Log({ kind = "variant_browse", itemID = c.itemID, name = c.name,
            results = results and #results or "no_answer", sameItem = #keys, keys = table.concat(texts, ", ") })
          local function searchKey(index)
            local key = keys[index]
            if not key or index > 3 then
              self:Next()
              return
            end
            self:WhenReady(function()
              self:Search(c.itemID, 0, nil, key, function(found)
                self:Log({ kind = "variant_key", itemID = c.itemID, key = keyText(key),
                  rows = found and #found or "no_answer", sample = found and rowsText(found) or nil,
                  keys = found and found[1] and found[1].itemKey or nil })
                searchKey(index + 1)
              end)
            end)
          end
          searchKey(1)
        end)
      end)
    end)
  end)
end

-- Lot item: compare the replicate lots with the item-search rows.
function Probe:RunLot(c)
  local level = self.client:ItemLevel(c.link)
  self:WhenReady(function()
    self:Search(c.itemID, Schema.SuffixOf(c.itemKey), level, nil, function(listings)
      local total, unit = 0, 0
      for _, row in ipairs(listings or {}) do
        for _, lot in ipairs(c.replicate) do
          if row.quantity == lot.quantity and row.quantity > 1 and row.buyoutTotal then
            if row.buyoutTotal == lot.total then total = total + 1 end
            if row.buyoutTotal * row.quantity == lot.total then unit = unit + 1 end
          end
        end
      end
      self.report.votes.total = self.report.votes.total + total
      self.report.votes.unit = self.report.votes.unit + unit
      local replicate = {}
      for index = 1, math.min(#c.replicate, 6) do
        replicate[index] = string.format("%dx%s", c.replicate[index].quantity, tostring(c.replicate[index].total))
      end
      self:Log({ kind = "lots", itemID = c.itemID, name = c.name, replicate = table.concat(replicate, " "),
        rows = listings and #listings or "no_answer", sample = listings and rowsText(listings) or nil,
        votesTotal = total, votesUnit = unit })
      self:Next()
    end)
  end)
end

function Probe:Next()
  if not self.running then return end
  self.index = self.index + 1
  local task = self.tasks[self.index]
  if not task then
    self.running = false
    self.report.finished = self.clock()
    if self.printer then self.printer("done", self.report) end
    return
  end
  if self.printer then self.printer("step", { index = self.index, total = #self.tasks, name = task.c.name }) end
  if task.kind == "variant" then self:RunVariant(task.c) else self:RunLot(task.c) end
end

-- Starts the probe. Returns ok, reason.
function Probe:Start()
  if self.running then return false, "busy" end
  if not self.ah:IsOpen() then return false, "ah_closed" end
  if self.scanner:IsActive() then return false, "busy" end
  local variants, lots = self:Candidates()
  self.tasks = {}
  for _, c in ipairs(variants) do self.tasks[#self.tasks + 1] = { kind = "variant", c = c } end
  for _, c in ipairs(lots) do self.tasks[#self.tasks + 1] = { kind = "lot", c = c } end
  if #self.tasks == 0 then return false, "nothing" end
  self.report = { started = self.clock(), results = {}, votes = { total = 0, unit = 0 },
    variants = #variants, lots = #lots }
  self.store.db.diagnostics.probe = self.report
  self.running, self.index = true, 0
  self:Next()
  return true
end

function Probe:Cancel()
  self.running = false
end
