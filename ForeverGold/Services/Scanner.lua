-- Scanner: read-only AH observation state machine (spec 6).
--
--   IDLE -> REQUESTED -> RECEIVING -> NORMALIZING -> COMPLETE
--                     \-> THROTTLED -> REQUESTED
--                     \-> FAILED / CANCELLED / PARTIAL
--
-- One AH task in flight. Every task carries a generation; closing the AH or
-- cancelling invalidates it, so late timers and events from an old task are
-- ignored. Events carry no request id: the scanner serializes work and
-- compares item keys and state instead. Nothing here can spend money.
--
-- Bus events: "scanner.state"(state, reason, snapshot)
--             "scanner.progress"(phase, done, total, snapshot)  phase: read | recheck
--             "scanner.snapshot"(snapshot, listings)
--             "quotes.invalidate"(reason)
local _, ns = ...

local Schema = ns.Data.Schema
local Capabilities = ns.Core.Capabilities
local Scanner = {}
ns.Services.Scanner = Scanner

Scanner.ACTIVE = { REQUESTED = true, RECEIVING = true, NORMALIZING = true, THROTTLED = true }

-- Replicate cooldown measured in game, counted from the last answered
-- request: silent at +14 min 27 s, answered at +15 min 38 s (2026-10-20,
-- build 70450, six requests). Silent requests do not restart it. Used only
-- as the starting measurement; every attempt keeps refining it.
Scanner.MEASURED = { lowerBound = 867, upperBound = 938, source = "2026-10-20 build 70450" }
Scanner.DEFAULTS = {
  timeout = 60, -- seconds without any replicate event: no response
  settle = 2, -- seconds without new update events before reading
  -- No automatic re-request after a silent server: in game (2026-10-20) a
  -- silent replicate meant cooldown, and re-requesting may extend it.
  maxRetries = 0,
  maxThrottleWaits = 3, -- waits for the throttle system before giving up
  -- Pacing after an unanswered replicate request (not a cooldown claim). In
  -- game an answer came 2 min 26 s after a silent request, so silent requests
  -- do not restart the cooldown and a short pause is enough.
  silentPause = 90,
  backoffBase = 5,
  backoffCap = 60,
  infoWait = 3, -- wait before re-reading rows still missing item data
  infoRounds = 4, -- bounded number of such re-reads
  samples = 8, -- multi-unit rows kept as evidence of the buyout meaning
  links = 6, -- item strings kept as evidence of the link format
  searchTimeout = 10,
  observeDedupe = 60, -- identical observation of one item ignored this long
  budgetMs = 2,
  progressEvery = 250, -- rows between progress events
}

-- deps: { adapter, scheduler, clock, bus, marketKey(), build(), trace?(kind, data),
--         memory? (persisted table for the measured replicate cooldown) }
function Scanner.New(deps, opts)
  local self = setmetatable({}, { __index = Scanner })
  self.adapter, self.scheduler, self.clock, self.bus = deps.adapter, deps.scheduler, deps.clock, deps.bus
  self.marketKey, self.build, self.trace = deps.marketKey, deps.build, deps.trace
  self.memory = deps.memory or {}
  self.memory.observations = self.memory.observations or {}
  self.opts = {}
  for key, value in pairs(Scanner.DEFAULTS) do self.opts[key] = value end
  for key, value in pairs(opts or {}) do self.opts[key] = value end
  self.state, self.sequence, self.lastObserved = "IDLE", 0, {}
  self.adapter:SetCallbacks({
    onShow = function() self:Trace("ah_show") end,
    onClose = function() self:OnClose() end,
    onReplicateUpdate = function() self:OnReplicateUpdate() end,
    onThrottleReady = function() self:OnThrottleReady() end,
    onThrottleDropped = function() self:Trace("throttle_dropped", { state = self.state }) end,
    onCommodityResults = function(itemID) self:OnCommodityResults(itemID) end,
    onItemResults = function(itemKey) self:OnItemResults(itemKey) end,
  })
  return self
end

function Scanner:Trace(kind, data)
  if self.trace then self.trace(kind, data) end
end

local function setState(self, state, reason)
  self.state, self.reason = state, reason
  self:Trace("state", { state = state, reason = reason })
  if self.bus then self.bus:Publish("scanner.state", state, reason, self.snapshot) end
end

function Scanner:IsActive()
  return Scanner.ACTIVE[self.state] == true
end

local function newSnapshot(self, mode, scope)
  self.sequence = self.sequence + 1
  local now = self.clock()
  return Schema.NewSnapshot({
    id = string.format("%d-%d", now, self.sequence), marketKey = self.marketKey(), mode = mode,
    scope = scope, build = self.build and self.build() or nil, started = now,
  })
end

local function progress(self, phase, done, total)
  if self.bus then self.bus:Publish("scanner.progress", phase, done, total, self.snapshot) end
end

local function discard(snapshot, reason)
  snapshot.counts.discarded = snapshot.counts.discarded + 1
  snapshot.discardReasons[reason] = (snapshot.discardReasons[reason] or 0) + 1
end

local function current(self, task)
  return self.task == task and task ~= nil
end

local function finish(self, task, state, reason)
  if not current(self, task) then return end
  local snapshot = self.snapshot
  snapshot.finished = self.clock()
  snapshot.status = state == "COMPLETE" and "complete" or (state == "PARTIAL" and "partial" or "failed")
  snapshot.reason = reason
  snapshot.updates, snapshot.lateUpdates, snapshot.rounds = task.updates, task.lateUpdates, task.rounds
  local listings = {}
  if task.byIndex then
    local indexes = {}
    for index in pairs(task.byIndex) do indexes[#indexes + 1] = index end
    table.sort(indexes)
    local keys = {}
    for _, index in ipairs(indexes) do
      local listing = task.byIndex[index]
      listings[#listings + 1] = listing
      if not keys[listing.itemKey] then
        keys[listing.itemKey] = true
        snapshot.counts.itemKeys = snapshot.counts.itemKeys + 1
      end
      snapshot.counts.units = snapshot.counts.units + listing.quantity
      if not listing.complete then snapshot.counts.incomplete = snapshot.counts.incomplete + 1 end
    end
    snapshot.counts.valid = #listings
  end
  self.task = nil
  setState(self, state, reason)
  if (state == "COMPLETE" or state == "PARTIAL") and self.bus then
    self.bus:Publish("scanner.snapshot", snapshot, listings)
  end
end

local function fail(self, task, reason)
  finish(self, task, "FAILED", reason)
end

-- Replicate --------------------------------------------------------------

local attempt

-- Replicate cooldown, measured instead of assumed. Relative to the last
-- request that got an answer: a silent request at +X proves the cooldown is
-- longer than X (lowerBound); an answered one at +Y proves it is at most Y
-- (upperBound). After a silent request the next one waits silentPause, so
-- the server is not hammered and each attempt narrows the measurement.
local function observe(self, answered, requestedAt)
  local memory = self.memory
  local since = memory.lastSuccess and (requestedAt - memory.lastSuccess) or nil
  if answered then
    if since and (not memory.upperBound or since < memory.upperBound) then memory.upperBound = since end
    memory.lastSuccess = requestedAt
  else
    memory.lastSilent = requestedAt
    if since and (not memory.lowerBound or since > memory.lowerBound) then memory.lowerBound = since end
  end
  local list = memory.observations
  list[#list + 1] = { t = requestedAt, answered = answered, since = since }
  while #list > 20 do table.remove(list, 1) end
end

-- { lastSuccess, lowerBound, upperBound, remaining, kind } at time now.
-- kind "measured": still inside the proven lower bound after the last
-- answered request; kind "silent": pacing pause after an unanswered one.
function Scanner:Cooldown(now)
  local memory = self.memory
  local info = { lastSuccess = memory.lastSuccess, lowerBound = memory.lowerBound, upperBound = memory.upperBound, remaining = 0 }
  now = now or self.clock()
  if memory.lastSuccess and memory.lowerBound then
    local left = memory.lastSuccess + memory.lowerBound - now
    if left > 0 then info.remaining, info.kind = left, "measured" end
  end
  if memory.lastSilent and (not memory.lastSuccess or memory.lastSilent > memory.lastSuccess) then
    local left = memory.lastSilent + self.opts.silentPause - now
    if left > info.remaining then info.remaining, info.kind = left, "silent" end
  end
  return info
end

local function retry(self, task, reason, limit)
  if task.attempts > (limit or self.opts.maxRetries) then
    fail(self, task, reason)
    return
  end
  local delay = self.scheduler:Backoff(task.attempts, self.opts.backoffBase, self.opts.backoffCap)
  self:Trace("retry", { reason = reason, delay = delay, attempt = task.attempts })
  task.retryTimer = self.scheduler:After(delay, function()
    if current(self, task) then attempt(self, task) end
  end)
end

attempt = function(self, task)
  task.attempts = task.attempts + 1
  local ready = self.adapter:IsReady()
  if ready == false then
    setState(self, "THROTTLED", "not_ready")
    retry(self, task, "throttled", self.opts.maxThrottleWaits)
    return
  end
  local ok, err = self.adapter:RequestReplicate()
  if not ok then
    fail(self, task, "request_failed:" .. tostring(err))
    return
  end
  task.requestedAt = self.clock()
  setState(self, "REQUESTED")
  task.timeoutTimer = self.scheduler:After(self.opts.timeout, function()
    if current(self, task) and self.state == "REQUESTED" then
      observe(self, false, task.requestedAt)
      retry(self, task, "no_response")
    end
  end)
end

-- request: { mode = "replicate" }. Returns ok, reason (, seconds left).
function Scanner:Start(request)
  request = request or { mode = "replicate" }
  if self:IsActive() then return false, "busy" end
  if not self.adapter:IsOpen() then return false, "ah_closed" end
  if request.mode ~= "replicate" then return false, "unsupported_mode" end
  if not self.adapter:GetCapabilities().replicate then return false, "unsupported" end
  local cooldown = self:Cooldown()
  if cooldown.remaining > 0 then return false, "cooldown", cooldown.remaining, cooldown.kind end
  self.scheduler:Invalidate()
  local task = { mode = "replicate", attempts = 0, updates = 0, lateUpdates = 0, rounds = 0, byIndex = {} }
  self.task = task
  self.snapshot = newSnapshot(self, "replicate", "all")
  attempt(self, task)
  return true
end

function Scanner:OnThrottleReady()
  self:Trace("throttle_ready", { state = self.state })
  local task = self.task
  if task and self.state == "THROTTLED" then
    if task.retryTimer then task.retryTimer.Cancel() end
    attempt(self, task)
  end
end

local function coverageOf(task, snapshot)
  if task.incompleteLeft > 0 or snapshot.counts.discarded > 0 then return "partial" end
  if Capabilities.IsVerified("replicate") then return "full_verified" end
  return "full_unverified"
end

local function readRow(self, task, index)
  local snapshot = self.snapshot
  local row, reason = self.adapter:ReadReplicateRow(index)
  if not row then
    discard(snapshot, reason or "unreadable")
    return
  end
  if type(row.itemID) ~= "number" or row.itemID <= 0 then
    discard(snapshot, "item_id")
    return
  end
  local _, suffix, bonus = Schema.VariantFromLink(row.link)
  if bonus and bonus ~= "" then snapshot.counts.withBonus = (snapshot.counts.withBonus or 0) + 1 end
  -- Evidence for docs/API-AUDIT.md: a few stacks and raw item strings.
  if row.count and row.count > 1 and row.buyout and #snapshot.samples < self.opts.samples then
    snapshot.samples[#snapshot.samples + 1] = { itemID = row.itemID, count = row.count, buyout = row.buyout, minBid = row.minBid }
  end
  local itemString = row.link and row.link:match("item:[%-%d:]+")
  if itemString and #snapshot.links < self.opts.links and (suffix ~= 0 or #snapshot.links < self.opts.links / 2) then
    snapshot.links[#snapshot.links + 1] = itemString
  end
  local itemKey = Schema.ItemKey(row.itemID, suffix, suffix == nil, bonus)
  local buyout = row.buyout
  if buyout == 0 then buyout = nil end
  local listing, why = Schema.NewListing({
    marketKey = snapshot.marketKey, itemKey = itemKey, quantity = row.count,
    -- Assumed whole-stack total until Capabilities.VERIFIED.replicateBuyoutIsTotal.
    buyoutTotal = buyout, bid = row.bidAmount, divisible = false,
    seen = self.clock(), source = "replicate", scanId = snapshot.id, index = index,
    complete = row.hasAllInfo and suffix ~= nil,
    link = (bonus and bonus ~= "") and row.link or nil,
  })
  if not listing then
    discard(snapshot, why)
    return
  end
  task.byIndex[index] = listing
  if not listing.complete then task.incomplete[#task.incomplete + 1] = index end
end

local function readIndexes(self, task, indexes, done)
  self.scheduler:Chunk(1, #indexes, self.opts.budgetMs, function(position)
    readRow(self, task, indexes[position])
  end, done)
end

local function beginNormalize(self, task)
  if not current(self, task) then return end
  setState(self, "NORMALIZING")
  local count = self.adapter:NumReplicate()
  if not count then
    fail(self, task, "count_unavailable")
    return
  end
  local base = self.adapter:DetectIndexBase(count)
  local snapshot = self.snapshot
  snapshot.indexBase, snapshot.counts.rows = base, count
  task.incomplete = {}
  self:Trace("normalize", { rows = count, base = base, updates = task.updates })
  local read, every = 0, self.opts.progressEvery
  progress(self, "read", 0, count)
  self.scheduler:Chunk(base, base + count - 1, self.opts.budgetMs, function(index)
    readRow(self, task, index)
    read = read + 1
    if read % every == 0 or read == count then progress(self, "read", read, count) end
  end, function(completed)
    if not completed or not current(self, task) then return end
    local pending = task.incomplete
    task.incompleteLeft = #pending
    if #pending == 0 then
      local coverage = coverageOf(task, snapshot)
      snapshot.coverage = coverage
      finish(self, task, coverage == "full_verified" and "COMPLETE" or "PARTIAL",
        coverage == "full_verified" and nil or "completeness_unverified")
      return
    end
    -- Item data keeps arriving (the client sends many updates meanwhile):
    -- re-read only the incomplete rows, a bounded number of times.
    local function round(rows)
      self.scheduler:After(self.opts.infoWait, function()
        if not current(self, task) then return end
        task.rounds = task.rounds + 1
        progress(self, "recheck", task.rounds, self.opts.infoRounds)
        task.incomplete = {}
        readIndexes(self, task, rows, function(again)
          if not again or not current(self, task) then return end
          task.incompleteLeft = #task.incomplete
          if task.incompleteLeft > 0 and task.rounds < self.opts.infoRounds then
            round(task.incomplete)
            return
          end
          snapshot.coverage = coverageOf(task, snapshot)
          finish(self, task, snapshot.coverage == "full_verified" and "COMPLETE" or "PARTIAL",
            task.incompleteLeft > 0 and "rows_incomplete" or "completeness_unverified")
        end)
      end)
    end
    round(pending)
  end)
end

function Scanner:OnReplicateUpdate()
  local task = self.task
  if not task or task.mode ~= "replicate" or (self.state ~= "REQUESTED" and self.state ~= "RECEIVING") then
    -- Late or foreign update: nothing is appended. The client sends these
    -- by the hundred while item data loads, so they are counted, and only
    -- traced at 1, 10, 100... to keep the bounded trace useful.
    if task and task.mode == "replicate" then task.lateUpdates = task.lateUpdates + 1 end
    self.ignoredUpdates = (self.ignoredUpdates or 0) + 1
    local n = self.ignoredUpdates
    if n == 1 or n == 10 or n == 100 or n == 1000 or n == 10000 then
      self:Trace("replicate_update_ignored", { state = self.state, count = n })
    end
    return
  end
  task.updates = task.updates + 1
  if task.updates == 1 then observe(self, true, task.requestedAt) end
  if task.timeoutTimer then task.timeoutTimer.Cancel() end
  if task.settleTimer then task.settleTimer.Cancel() end
  if self.state ~= "RECEIVING" then setState(self, "RECEIVING") end
  task.settleTimer = self.scheduler:After(self.opts.settle, function() beginNormalize(self, task) end)
end

-- Cancel and close ---------------------------------------------------------

function Scanner:Cancel(reason)
  local task = self.task
  self.scheduler:Invalidate()
  if task then finish(self, task, "CANCELLED", reason or "user") end
end

function Scanner:OnClose()
  self:Trace("ah_closed", { state = self.state })
  if self.bus then self.bus:Publish("quotes.invalidate", "ah_closed") end
  local task = self.task
  if not task then return end
  self.scheduler:Invalidate()
  local read = 0
  for _ in pairs(task.byIndex or {}) do read = read + 1 end
  if read > 0 then
    self.snapshot.coverage = "partial"
    finish(self, task, "PARTIAL", "ah_closed")
  else
    finish(self, task, "CANCELLED", "ah_closed")
  end
end

-- Search results: targeted refresh or passive observation ----------------

local function signature(listings)
  local quantity, total = 0, 0
  for _, listing in ipairs(listings) do
    quantity = quantity + listing.quantity
    total = total + (listing.buyoutTotal or 0)
  end
  return #listings .. ":" .. quantity .. ":" .. total
end

-- Normalizes search rows into listings for one item key.
local function searchListings(self, snapshot, rows, commodity)
  local listings = {}
  for index, row in ipairs(rows) do
    local raw = {
      marketKey = snapshot.marketKey, quantity = row.quantity, auctionID = row.auctionID,
      seen = self.clock(), scanId = snapshot.id, index = index, own = row.own,
    }
    if commodity then
      raw.itemKey = Schema.ItemKey(row.itemID, 0)
      raw.divisible, raw.unitPrice, raw.source = true, row.unitPrice, "search_commodity"
    else
      local _, suffix, bonus = Schema.VariantFromLink(row.link)
      raw.itemKey = Schema.ItemKey(row.itemID, suffix or row.suffix or 0, false, bonus)
      raw.divisible, raw.buyoutTotal, raw.bid, raw.source = false, row.buyout, row.minBid, "search_item"
      if row.quantity ~= 1 and not Capabilities.IsVerified("itemSearchBuyoutIsTotal") then
        raw.complete = false -- price per unit or per auction not verified
      end
    end
    local listing, why = Schema.NewListing(raw)
    if listing then listings[#listings + 1] = listing else discard(snapshot, why) end
  end
  return listings
end

local function publishObservation(self, snapshot, listings, full)
  snapshot.finished = self.clock()
  snapshot.coverage = full == true and "full_unverified" or "partial"
  snapshot.status = "partial"
  snapshot.counts.rows = #listings + snapshot.counts.discarded
  snapshot.counts.valid = #listings
  snapshot.counts.itemKeys = #listings > 0 and 1 or 0
  for _, listing in ipairs(listings) do snapshot.counts.units = snapshot.counts.units + listing.quantity end
  if self.bus then self.bus:Publish("scanner.snapshot", snapshot, listings) end
end

local function observeSearch(self, scopeKey, rows, full, commodity)
  local snapshot = newSnapshot(self, "observed_search", scopeKey)
  local listings = searchListings(self, snapshot, rows, commodity)
  local sig = signature(listings)
  local last = self.lastObserved[scopeKey]
  local now = self.clock()
  if last and last.sig == sig and now - last.t < self.opts.observeDedupe then
    self:Trace("observation_duplicate", { scope = scopeKey })
    return
  end
  self.lastObserved[scopeKey] = { sig = sig, t = now }
  publishObservation(self, snapshot, listings, full)
end

local function handleResults(self, itemID, suffix, commodity, readFn)
  local task = self.task
  local scopeKey = Schema.ItemKey(itemID, suffix or 0)
  if task and task.mode == "search" then
    if task.itemID ~= itemID then
      -- Someone else changed the search: suspend instead of guessing.
      if task.timeoutTimer then task.timeoutTimer.Cancel() end
      fail(self, task, "search_changed")
      return
    end
    if task.timeoutTimer then task.timeoutTimer.Cancel() end
    local rows, full = readFn()
    local snapshot = self.snapshot
    local listings = searchListings(self, snapshot, rows, commodity)
    local callback = task.callback
    snapshot.coverage = full == true and "full_unverified" or "partial"
    task.byIndex = {}
    for index, listing in ipairs(listings) do task.byIndex[index] = listing end
    finish(self, task, "PARTIAL", full == true and "completeness_unverified" or "results_partial")
    if callback then callback(snapshot, listings) end
    return
  end
  -- While a replicate request only waits for the server, the user's own
  -- searches are still observed; during reading they are not.
  local waiting = task and task.mode == "replicate" and (self.state == "REQUESTED" or self.state == "THROTTLED")
  if self:IsActive() and not waiting then return end
  observeSearch(self, scopeKey, readFn())
end

function Scanner:OnCommodityResults(itemID)
  self:Trace("commodity_results", { itemID = itemID, state = self.state })
  handleResults(self, itemID, 0, true, function()
    local rows, full = self.adapter:ReadCommodityResults(itemID)
    return rows, full, true
  end)
end

function Scanner:OnItemResults(itemKey)
  local itemID = itemKey.itemID
  if type(itemID) ~= "number" then return end
  self:Trace("item_results", { itemID = itemID, state = self.state })
  handleResults(self, itemID, itemKey.itemSuffix, false, function()
    local rows, full = self.adapter:ReadItemResults(itemKey)
    return rows, full, false
  end)
end

-- Targeted read-only search for one item, e.g. to refresh a quote.
-- callback(snapshot, listings) on results. Returns ok, reason.
function Scanner:Search(itemID, suffix, callback, itemLevel)
  if self:IsActive() then return false, "busy" end
  if not self.adapter:IsOpen() then return false, "ah_closed" end
  if not self.adapter:GetCapabilities().targetedSearch then return false, "unsupported" end
  if self.adapter:IsReady() == false then return false, "throttled" end
  self.scheduler:Invalidate()
  local task = { mode = "search", itemID = itemID, attempts = 1, callback = callback }
  self.task = task
  self.snapshot = newSnapshot(self, "search", Schema.ItemKey(itemID, suffix or 0))
  local ok, err = self.adapter:SendSearch(itemID, suffix, itemLevel)
  if not ok then
    fail(self, task, "request_failed:" .. tostring(err))
    return false, "request_failed"
  end
  setState(self, "REQUESTED")
  task.timeoutTimer = self.scheduler:After(self.opts.searchTimeout, function()
    if current(self, task) then fail(self, task, "no_response") end
  end)
  return true
end
