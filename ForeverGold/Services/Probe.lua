-- Probe: read-only AH investigation started by the user ("AH search test").
-- It runs a few searches and browses, one at a time and only when the AH is
-- ready, and records what the server answers in ForeverGoldDB.diagnostics.probe:
--   variants  items with bonus IDs: direct search with the built key, then a
--             browse by name and a search with each server key of the item;
--   lots      non-commodity items sold in lots of 2+ or stackable: replicate
--             lots vs the item-search rows, to learn whether buyoutAmount is
--             per lot or per unit (votes "total" / "unit"; a same-price row
--             with another lot size is recorded as a mismatch).
-- Nothing is bought, bid, posted or cancelled.
local _, ns = ...

local Schema = ns.Data.Schema
local Probe = {}
ns.Services.Probe = Probe

Probe.MAX_VARIANTS = 4
Probe.MAX_LOTS = 8
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
        -- Lots of 2+, or stackable items (the search may show bigger lots
        -- than the replicate); commodities are left out, unknown ones kept.
        local stackable = (info.stackCount or 1) > 1
        -- Two or more single-unit auctions at the same price: the search may
        -- group them into one row (then its price would be per unit).
        local samePrice = 0
        for _, other in ipairs(view.listings) do
          if other.quantity == 1 and other.buyoutTotal == listing.buyoutTotal then samePrice = samePrice + 1 end
        end
        local grouped = listing.quantity == 1 and samePrice >= 2
        if (listing.quantity > 1 or stackable or grouped) and listing.buyoutTotal and not listing.divisible
          and not seenL[itemID] and self.ah:IsCommodity(itemID) ~= true then
          seenL[itemID] = true
          local replicate = {}
          for _, other in ipairs(view.listings) do
            if other.buyoutTotal then replicate[#replicate + 1] = { quantity = other.quantity, total = other.buyoutTotal } end
          end
          lots[#lots + 1] = { itemID = itemID, itemKey = itemKey, name = info.name, link = listing.link, replicate = replicate,
            multi = listing.quantity > 1 or grouped, grouped = grouped, stackCount = info.stackCount }
        end
      end
    end
  end
  -- Lots of 2+ first, then the stackable ones.
  table.sort(lots, function(a, b)
    if a.multi ~= b.multi then return a.multi end
    return a.itemID < b.itemID
  end)
  while #lots > Probe.MAX_LOTS do table.remove(lots) end
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
  local commodity = self.ah:IsCommodity(c.itemID)
  if commodity == true then
    self:Log({ kind = "lots_skip", itemID = c.itemID, name = c.name, reason = "commodity" })
    self:Next()
    return
  end
  self:WhenReady(function()
    self:Search(c.itemID, Schema.SuffixOf(c.itemKey), level, nil, function(listings)
      -- total: a row of q units costs what a replicate lot of q costs, or
      --        what q single replicate auctions cost together;
      -- unit:  a row of q units costs what one unit costs in the replicate
      --        (q single auctions grouped into one row at the unit price).
      local total, unit, mismatch = 0, 0, 0
      for _, row in ipairs(listings or {}) do
        if row.quantity > 1 and row.buyoutTotal then
          local rowTotal, rowUnit = false, false
          for _, lot in ipairs(c.replicate) do
            if row.quantity == lot.quantity then
              if row.buyoutTotal == lot.total then rowTotal = true end
              if row.buyoutTotal * row.quantity == lot.total then rowUnit = true end
            elseif lot.quantity == 1 then
              if row.buyoutTotal == lot.total then rowUnit = true end
              if row.buyoutTotal == lot.total * row.quantity then rowTotal = true end
            elseif row.buyoutTotal == lot.total then
              mismatch = mismatch + 1
            end
          end
          if rowTotal and not rowUnit then total = total + 1 end
          if rowUnit and not rowTotal then unit = unit + 1 end
        end
      end
      self.report.votes.total = self.report.votes.total + total
      self.report.votes.unit = self.report.votes.unit + unit
      self.report.votes.mismatch = (self.report.votes.mismatch or 0) + mismatch
      local replicate = {}
      for index = 1, math.min(#c.replicate, 6) do
        replicate[index] = string.format("%dx%s", c.replicate[index].quantity, tostring(c.replicate[index].total))
      end
      self:Log({ kind = "lots", itemID = c.itemID, name = c.name, replicate = table.concat(replicate, " "),
        rows = listings and #listings or "no_answer", sample = listings and rowsText(listings) or nil,
        votesTotal = total, votesUnit = unit, sizeMismatch = mismatch, stackCount = c.stackCount, grouped = c.grouped,
        commodity = tostring(commodity) })
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
