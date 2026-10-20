-- App: wires adapters, data, services and UI hooks together.
-- Built from an injected `env` (the global table in game, a fake offline),
-- so the whole addon can be loaded and driven by the offline tests.
local _, ns = ...

local App = {}
ns.Core.App = App

function App.New(env)
  local self = setmetatable({ env = env, loaded = false }, { __index = App })
  local client = ns.Compat.ClientAdapter.New(env)
  self.client = client
  self.capabilities = ns.Core.Capabilities.New()
  self.schedulerEnv = client:SchedulerEnv()
  self.clock = self.schedulerEnv.now
  self.bus = ns.Core.EventBus.New(function(message) self:Log(message) end)
  return self
end

function App:Log(message)
  self.errors = self.errors or {}
  self.errors[#self.errors + 1] = message
  while #self.errors > 20 do table.remove(self.errors, 1) end
end

-- saved: the SavedVariables table as handed over by the client.
-- Returns the table to assign back to the global.
function App:Load(saved)
  local clock = self.clock
  self.store = ns.Data.Store.New(saved, { now = clock() })
  -- Evidence the addon gathered itself on this client (e.g. vendor check).
  self.store.db.verifiedRuntime = self.store.db.verifiedRuntime or {}
  ns.Core.Capabilities.runtime = self.store.db.verifiedRuntime
  self.client:Detect(self.capabilities)
  self.scheduler = ns.Core.Scheduler.New(self.schedulerEnv)
  self.work = ns.Core.Scheduler.New(self.schedulerEnv) -- history and evaluation steps
  self.ah = ns.Compat.AuctionHouse.New(self.client)
  self.items = ns.Compat.Items.New(self.client, ns.Core.Scheduler.New(self.schedulerEnv), function(itemID)
    self.bus:Publish("items.resolved", itemID)
  end)
  self.professions = ns.Compat.Professions.New(self.client)
  self.history = ns.Data.History.New(self.store, clock)
  self.events = { registered = {}, rejected = {} }
  self.diagnostics = ns.Services.Diagnostics.New({
    client = self.client, capabilities = self.capabilities, store = self.store, clock = clock, events = self.events,
  })
  local settings = self.store:Settings()
  self.scanner = ns.Services.Scanner.New({
    adapter = self.ah, scheduler = self.scheduler, clock = clock, bus = self.bus,
    marketKey = function() return self:MarketKey() end,
    build = function() return self.client:BuildInfo().version end,
    trace = function(kind, data) self.diagnostics:Trace(kind, data) end,
    memory = self:ScannerMemory(),
  }, { budgetMs = settings.frameBudgetMs })
  self.opportunities = ns.Services.Opportunities.New({
    store = self.store, history = self.history, items = self.items, clock = clock, bus = self.bus,
    commodity = function(itemID) return self.ah:IsCommodity(itemID) end,
  })
  self.transactions = ns.Services.Transactions.New(clock)
  self.purchases = ns.Services.Purchases.New({
    purchase = ns.Compat.Purchase.New(self.client), client = self.client, scanner = self.scanner,
    scheduler = ns.Core.Scheduler.New(self.schedulerEnv), clock = clock, bus = self.bus, store = self.store,
    trace = function(kind, data) self.diagnostics:Trace(kind, data) end,
    isReady = function() return self.ah:IsReady() end,
  })
  self.batch = ns.Services.Batch.New({ purchases = self.purchases, client = self.client, bus = self.bus, clock = clock,
    stale = function() return self.opportunities.stale end })
  self.bus:Subscribe("purchase.state", function(current) self.batch:OnPurchase(current) end)
  self.probe = ns.Services.Probe.New({
    scanner = self.scanner, ah = self.ah, client = self.client, items = self.items, opportunities = self.opportunities,
    scheduler = ns.Core.Scheduler.New(self.schedulerEnv), clock = clock, store = self.store,
    printer = function(kind, data) self.bus:Publish("probe.progress", kind, data) end,
  })
  self.vendorCheck = ns.Services.VendorCheck.New({
    client = self.client, store = self.store, clock = clock,
    printer = function(report) self.bus:Publish("vendor.check", report) end,
  })
  -- Callbacks beyond the scanner's own: commodity info and purchase events.
  self.ah.callbacks.onItemKeyInfo = function(itemID) self.bus:Publish("items.resolved", itemID) end
  self.ah.callbacks.onPurchase = function(event, ...) self.purchases:OnEvent(event, ...) end
  local scannerReady = self.ah.callbacks.onThrottleReady
  self.ah.callbacks.onThrottleReady = function()
    scannerReady()
    self.purchases:OnReady()
  end
  self:Subscribe()
  self.loaded = true
  -- Trim saved data written by older versions (smaller file, less memory).
  self.history:Prune(clock(), nil)
  self:RestoreView()
  return self.store:Persisted(saved)
end

-- Listing fields kept across /reload (plain data only).
local VIEW_FIELDS = { "marketKey", "itemKey", "quantity", "buyoutTotal", "unitPrice", "divisible", "auctionID", "source",
  "scanId", "complete", "buyable", "own", "seen", "id", "link" }

-- Saves the opportunities and the auctions behind them, so the list
-- survives /reload and relog while the replicate is cooling down.
function App:SaveView()
  local results = self.opportunities.results
  if not results or results.demo or not results.snapshot then return end
  local keys = {}
  for _, o in ipairs(results.list) do
    keys[o.itemKey] = true
    for _, lot in ipairs(o.lots or {}) do
      if lot.listing and lot.listing.itemKey then keys[lot.listing.itemKey] = true end
    end
  end
  local listings = {}
  for itemKey in pairs(keys) do
    local view = self.opportunities.latest[itemKey]
    for _, listing in ipairs(view and view.listings or {}) do
      local copy = {}
      for _, field in ipairs(VIEW_FIELDS) do copy[field] = listing[field] end
      listings[#listings + 1] = copy
    end
  end
  local s = results.snapshot
  self.store.db.lastView = {
    snapshot = { id = s.id, marketKey = s.marketKey, mode = s.mode, scope = s.scope, coverage = s.coverage,
      started = s.started, finished = s.finished, counts = s.counts },
    listings = listings,
  }
end

function App:RestoreView()
  local saved = self.store.db.lastView
  if type(saved) ~= "table" or type(saved.snapshot) ~= "table" or type(saved.listings) ~= "table" then return false end
  local snapshot = ns.CopyTable(saved.snapshot)
  snapshot.restored = true
  self.opportunities:Ingest(snapshot, ns.CopyTable(saved.listings))
  self:EvaluateChunked(nil, "restored")
  return true
end

-- Persisted scanner measurements (replicate cooldown bounds), seeded with
-- the bounds measured in game when nothing has been measured yet.
function App:ScannerMemory()
  local db = self.store.db
  db.scanner = db.scanner or {}
  local memory, measured = db.scanner, ns.Services.Scanner.MEASURED
  if memory.lowerBound == nil and memory.upperBound == nil then
    memory.lowerBound, memory.upperBound, memory.seed = measured.lowerBound, measured.upperBound, measured.source
  end
  return memory
end

function App:MarketKey()
  if not self.marketKeyCache then
    self.marketKeyCache = ns.Data.Schema.MarketKey(self.client:MarketFields())
  end
  return self.marketKeyCache
end

function App:Subscribe()
  local bus = self.bus
  bus:Subscribe("scanner.snapshot", function(snapshot, listings) self:Process(snapshot, listings) end)
  bus:Subscribe("items.resolved", function()
    if self.reevaluatePending then return end
    self.reevaluatePending = true
    self.scheduler:After(1, function()
      self.reevaluatePending = false
      if not self.processing then self:EvaluateChunked() end
    end)
  end)
  bus:Subscribe("quotes.invalidate", function(reason)
    self.transactions:Invalidate(reason)
    self.purchases:Cancel(reason)
  end)
end

-- Snapshot pipeline: history, then evaluation, both spread over frames
-- within the configured budget. A newer snapshot restarts the pipeline.
-- Bus: "pipeline.progress"(phase, done, total, mode), phase history | evaluate | done.
local PROGRESS_EVERY = 100

function App:Progress(phase, done, total, mode)
  self.bus:Publish("pipeline.progress", phase, done, total, mode)
end

function App:Process(snapshot, listings)
  local work, budget = self.work, self.store:Settings().frameBudgetMs
  work:Invalidate()
  self.processing = true
  if snapshot.mode == "replicate" then snapshot.buyoutVotes = ns.Services.Diagnostics.BuyoutVotes(listings) end
  local job = self.history:BeginRecord(snapshot, listings)
  local total = #job.order
  self:Progress("history", 0, total, snapshot.mode)
  work:Chunk(1, total, budget, function(index)
    ns.Data.History.RecordStep(job, index)
    if index % PROGRESS_EVERY == 0 then self:Progress("history", index, total, snapshot.mode) end
  end, function(done)
    if not done then return end
    ns.Data.History.FinishRecord(job)
    self.opportunities:Ingest(snapshot, listings)
    self:EvaluateChunked(function()
      -- A user scan is summarised by UI/Feedback; notices are for the rest.
      if snapshot.mode == "replicate" then return end
      self.opportunities:NotifyIfDue(function(good, counts)
        ns.Print(string.format(ns.L["NOTIFY_FOUND"], good, counts.itemKeys))
      end)
    end, snapshot.mode)
  end)
end

function App:EvaluateChunked(after, mode)
  local work, opportunities = self.work, self.opportunities
  self.processing = true
  local job = opportunities:BeginEvaluate()
  local total = #job.keys
  self:Progress("evaluate", 0, total, mode)
  work:Chunk(1, total, self.store:Settings().frameBudgetMs, function(index)
    opportunities:EvaluateStep(job, index)
    if index % PROGRESS_EVERY == 0 then self:Progress("evaluate", index, total, mode) end
  end, function(done)
    if not done then return end
    self.processing = false
    local results = opportunities:FinishEvaluate(job)
    self:SaveView()
    self:Progress("done", total, total, mode)
    if after then after(results) end
  end)
end

-- Client events forwarded by Core/Init.
function App:OnEvent(event, ...)
  if not self.loaded then return end
  if event == "GET_ITEM_INFO_RECEIVED" then
    self.items:OnItemInfo(...)
  elseif event == "PLAYER_LOGOUT" then
    self.history:Prune(self.clock(), nil)
  elseif event == "MERCHANT_SHOW" then
    self.vendorCheck:OnMerchantShow()
  elseif event == "MERCHANT_CLOSED" then
    self.vendorCheck:OnMerchantClosed()
  else
    if event == "AUCTION_HOUSE_SHOW" then self.marketKeyCache = nil end
    self.ah:OnEvent(event, ...)
  end
end

-- Demo mode: fixture data in a separate, in-memory market. Never mixed with
-- real history; everything shown is labelled DEMO.
function App:Demo()
  local demo = ns.Data.Demo
  local store = ns.Data.Store.New(nil, { now = self.clock() })
  local history = ns.Data.History.New(store, self.clock)
  local opportunities = ns.Services.Opportunities.New({ store = store, history = history, clock = self.clock })
  local snapshot, listings = demo.Build(self.clock(), history)
  opportunities:Ingest(snapshot, listings)
  opportunities.items = demo.Items()
  local results = opportunities:Evaluate()
  results.demo = true
  return results
end
