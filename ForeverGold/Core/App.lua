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
  self.craftWork = ns.Core.Scheduler.New(self.schedulerEnv) -- crafting steps
  self.ah = ns.Compat.AuctionHouse.New(self.client)
  self.items = ns.Compat.Items.New(self.client, ns.Core.Scheduler.New(self.schedulerEnv), function(itemID)
    self.bus:Publish("items.resolved", itemID)
  end)
  self.professions = ns.Compat.Professions.New(self.client)
  self.merchant = ns.Compat.Merchant.New(self.client)
  ns.Data.Recipes.Load(self.store.db.recipes)
  -- The first probe (32108fc) saved a report named "unknown" when called
  -- with no window open; it held the previous window's recipes.
  local professions = self.store.db.diagnostics and self.store.db.diagnostics.professions
  if professions then professions.unknown = nil end
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
    timing = function(phase, fields) self.diagnostics:Timing(phase, fields) end,
    memory = self:ScannerMemory(),
  }, { budgetMs = settings.frameBudgetMs })
  self.opportunities = ns.Services.Opportunities.New({
    store = self.store, history = self.history, items = self.items, clock = clock, bus = self.bus,
    commodity = function(itemID) return self.ah:IsCommodity(itemID) end,
    merchantPrice = function(itemID) return self:MerchantPrice(itemID) end,
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
  self.store.db.autoScan = self.store.db.autoScan or {}
  self.autoScan = ns.Services.AutoScan.New({
    scanner = self.scanner, ah = self.ah, scheduler = ns.Core.Scheduler.New(self.schedulerEnv), clock = clock,
    settings = function() return self.store:Settings() end, memory = self.store.db.autoScan, bus = self.bus,
    trace = function(kind, data) self.diagnostics:Trace(kind, data) end,
    -- Never while a scan is processed or a purchase uses the AH.
    busy = function()
      local current = self.purchases.current
      local using = current and (current.state == "waiting" or current.state == "quoting"
        or current.state == "locating" or current.state == "confirming")
      return self.processing == true or self.batch.active == true or using == true
    end,
  })
  self.bus:Subscribe("scanner.state", function(state, reason) self.autoScan:OnScannerState(state, reason) end)
  self.probe = ns.Services.Probe.New({
    scanner = self.scanner, ah = self.ah, client = self.client, items = self.items, opportunities = self.opportunities,
    scheduler = ns.Core.Scheduler.New(self.schedulerEnv), clock = clock, store = self.store,
    printer = function(kind, data) self.bus:Publish("probe.progress", kind, data) end,
  })
  self.feeTest = ns.Services.FeeTest.New({
    client = self.client, ah = self.ah, items = self.items, opportunities = self.opportunities, store = self.store,
    clock = clock, printer = function(kind, data) self.bus:Publish("feetest", kind, data) end,
  })
  self.ah.callbacks.onOwned = function() self.feeTest:OnOwnedAuctions() end
  self.ah.callbacks.onAuctionCreated = function() self.feeTest:OnBagsOrMoney() end
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
-- Per item only the auctions in an opportunity's lots and the cheapest
-- VIEW_CHEAPEST buyable ones are kept: on the live server one item had 3,285
-- auctions and the saved view grew to about 95,000 lines.
App.VIEW_CHEAPEST = 50

local function unitCost(listing)
  if not listing.buyable or not listing.buyoutTotal or (listing.quantity or 0) <= 0 then return math.huge end
  return listing.buyoutTotal / listing.quantity
end

function App:SaveView()
  local results = self.opportunities.results
  if not results or results.demo or not results.snapshot then return end
  local keys, used = {}, {}
  for _, o in ipairs(results.list) do
    keys[o.itemKey] = true
    for _, lot in ipairs(o.lots or {}) do
      local listing = lot.listing
      if listing and listing.itemKey then keys[listing.itemKey] = true end
      if listing and listing.id then used[listing.id] = true end
    end
  end
  local listings = {}
  for itemKey in pairs(keys) do
    local view = self.opportunities.latest[itemKey]
    local order = {}
    for _, listing in ipairs(view and view.listings or {}) do order[#order + 1] = listing end
    table.sort(order, function(a, b) return unitCost(a) < unitCost(b) end)
    for rank, listing in ipairs(order) do
      if rank <= App.VIEW_CHEAPEST or (listing.id and used[listing.id]) then
        local copy = {}
        for _, field in ipairs(VIEW_FIELDS) do copy[field] = listing[field] end
        listings[#listings + 1] = copy
      end
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

-- Runs fn in one go and records how long it blocked the frame.
function App:Timed(phase, rows, fn)
  local preciseMs = self.schedulerEnv.preciseMs
  local started = preciseMs()
  local a, b, c = fn()
  local spent = preciseMs() - started
  self.diagnostics:Timing(phase, { rows = rows, frames = 1, worstMs = spent, busyMs = spent })
  return a, b, c
end

-- Records a chunked phase from its scheduler handle; describe(index)
-- returns the key and row count of the slowest step.
function App:ChunkTiming(phase, handle, startedAt, describe)
  local slowestKey, slowestRows
  if describe and handle.slowestIndex then slowestKey, slowestRows = describe(handle.slowestIndex) end
  self.diagnostics:Timing(phase, { rows = handle.steps, frames = handle.frames, worstMs = handle.worstMs,
    busyMs = handle.busyMs, wall = self.clock() - startedAt, slowestMs = handle.slowestMs,
    slowestKey = slowestKey, slowestRows = slowestRows })
end

-- Every pass over the raw listings (about 160,000 on the live server) is
-- chunked: grouping for history, for the market view and for the buyout
-- evidence happens in one "group" phase; history then runs per item key.
function App:Process(snapshot, listings)
  local work, budget = self.work, self.store:Settings().frameBudgetMs
  local History, Diagnostics = ns.Data.History, ns.Services.Diagnostics
  work:Invalidate()
  self.processing = true
  local job, ingest, votes = self:Timed("history_begin", #listings, function()
    return self.history:BeginRecord(snapshot), ns.Services.Opportunities.BeginIngest(snapshot),
      snapshot.mode == "replicate" and Diagnostics.BuyoutVotesBegin() or nil
  end)
  local groupStarted = self.clock()
  self:Progress("history", 0, #listings, snapshot.mode)
  work:Chunk(1, #listings, budget, function(index)
    local listing = listings[index]
    History.AddListing(job, listing)
    ns.Services.Opportunities.IngestListing(ingest, listing)
    if votes then Diagnostics.BuyoutVotesAdd(votes, listing) end
  end, function(grouped, groupHandle)
    if not grouped then return end
    self:ChunkTiming("group", groupHandle, groupStarted)
    self:RecordHistory(snapshot, job, ingest, votes)
  end)
end

function App:RecordHistory(snapshot, job, ingest, votes)
  local History = ns.Data.History
  local total = #job.order
  local startedAt = self.clock()
  self:Progress("history", 0, total, snapshot.mode)
  self.work:Chunk(1, total, self.store:Settings().frameBudgetMs, function(index)
    History.RecordStep(job, index)
    if index % PROGRESS_EVERY == 0 then self:Progress("history", index, total, snapshot.mode) end
  end, function(done, handle)
    if not done then return end
    self:ChunkTiming("history", handle, startedAt, function(index)
      local key = job.order[index]
      return key, key and #job.byItem[key] or nil
    end)
    self:Timed("history_finish", total, function()
      if votes then snapshot.buyoutVotes = ns.Services.Diagnostics.BuyoutVotesFinish(votes) end
      History.FinishRecord(job)
      self.opportunities:FinishIngest(ingest)
    end)
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
  local job = self:Timed("evaluate_begin", nil, function() return opportunities:BeginEvaluate() end)
  local total = #job.keys
  local startedAt = self.clock()
  self:Progress("evaluate", 0, total, mode)
  work:Chunk(1, total, self.store:Settings().frameBudgetMs, function(index)
    opportunities:EvaluateStep(job, index)
    if index % PROGRESS_EVERY == 0 then self:Progress("evaluate", index, total, mode) end
  end, function(done, handle)
    if not done then return end
    self.processing = false
    self:ChunkTiming("evaluate", handle, startedAt, function(index)
      local key = job.keys[index]
      local view = key and opportunities.latest[key]
      return key, view and #view.listings or nil
    end)
    local results = self:Timed("evaluate_finish", total, function()
      local finished = opportunities:FinishEvaluate(job)
      self:SaveView()
      return finished
    end)
    self:EvaluateCrafting()
    self:Progress("done", total, total, mode)
    if after then after(results) end
  end)
end

-- Observes the open profession window (read-only) once its list settles:
-- the list events come in bursts while the window fills.
-- While a profession window stays open the client fires
-- TRADE_SKILL_LIST_UPDATE every 1-2 s (seen in game, build 70862): opening
-- a window always observes it, list updates at most every
-- PROFESSION_REFRESH seconds.
App.PROFESSION_REFRESH = 60

function App:ObserveProfessionSoon(opened)
  if self.professionPending then return end
  if not opened and self.professionObservedAt and self.clock() - self.professionObservedAt < App.PROFESSION_REFRESH then
    return
  end
  self.professionPending = true
  self.scheduler:After(1, function()
    self.professionPending = false
    self:ObserveProfession()
  end)
end

-- Returns the report, or nil, "no_window" when no profession window is open.
function App:ObserveProfession()
  -- One frame: about 500 recipes for Blacksmithing; timed to check in game.
  local report, catalogue = self:Timed("profession_observe", nil, function() return self.professions:Observe() end)
  if not report then return nil, catalogue end
  self.professionObservedAt = self.clock()
  self.diagnostics:RecordProfessions(report)
  local db = self.store.db
  db.recipes = db.recipes or {}
  local previous = db.recipes[report.name]
  local changed = not previous or App.CatalogueSignature(previous.list) ~= App.CatalogueSignature(catalogue)
  db.recipes[report.name] = {
    at = self.clock(), build = self.client:BuildInfo().build, skill = report.skill, maxSkill = report.maxSkill,
    list = catalogue,
  }
  -- Prices only change with a scan: re-price only when the recipes did.
  if changed then
    ns.Data.Recipes.Load(db.recipes)
    self:EvaluateCrafting()
  end
  return report, changed
end

-- Merchant prices (Compat/Merchant), kept in ForeverGoldDB.merchant.prices
-- [itemID] = { unit, at }: the lowest gold price per unit seen for an
-- unlimited offer. A price older than MERCHANT_MAX_AGE is replaced by the
-- next one seen even if higher (prices may change with reputation).
App.MERCHANT_MAX_AGE = 14 * 86400

function App:MerchantPrice(itemID)
  local merchant = self.store.db.merchant
  local entry = merchant and merchant.prices and merchant.prices[itemID]
  return entry and entry.unit or nil
end

function App:ObserveMerchantSoon()
  if self.merchantPending then return end
  self.merchantPending = true
  -- The item list may arrive just after MERCHANT_SHOW (MERCHANT_UPDATE).
  self.scheduler:After(1, function()
    self.merchantPending = false
    self:ObserveMerchant()
  end)
end

-- Returns the number of new or lower prices, or nil, reason.
function App:ObserveMerchant()
  local report, reason = self.merchant:Read()
  if not report then return nil, reason end
  local db = self.store.db
  db.merchant = db.merchant or {}
  db.merchant.prices = db.merchant.prices or {}
  local prices, now, changed, total = db.merchant.prices, self.clock(), 0, 0
  for itemID, unit in pairs(report.prices) do
    total = total + 1
    local known = prices[itemID]
    if not known or unit < known.unit or (unit ~= known.unit and now - (known.at or 0) > App.MERCHANT_MAX_AGE) then
      prices[itemID] = { unit = unit, at = now }
      changed = changed + 1
    elseif unit == known.unit then
      known.at = now
    end
  end
  db.diagnostics.merchant = {
    at = now, build = self.client:BuildInfo().build, rows = report.rows, priced = total, changed = changed,
    skipped = report.skipped, symbols = report.symbols, samples = report.samples,
  }
  self.diagnostics:Trace("merchant", { rows = report.rows, priced = total, changed = changed })
  if changed > 0 then self:EvaluateCrafting() end
  return changed
end

-- A recipe learned from a trainer or a recipe item: mark it in the saved
-- catalogue and re-price, without reopening the profession window.
-- Returns true when the recipe was in a catalogue.
function App:OnRecipeLearned(recipeID)
  self.diagnostics:Trace("recipe_learned", { recipeID = recipeID })
  for _, entry in pairs(self.store.db.recipes or {}) do
    for _, recipe in ipairs(entry.list or {}) do
      if recipe.id == recipeID then
        if recipe.learned then return true end
        recipe.learned = true
        ns.Data.Recipes.Load(self.store.db.recipes)
        self:EvaluateCrafting()
        return true
      end
    end
  end
  return false
end

-- Recipes and which of them are learned, as one comparable string.
function App.CatalogueSignature(list)
  local parts = {}
  for _, recipe in ipairs(list or {}) do parts[#parts + 1] = tostring(recipe.id) .. (recipe.learned and "+" or "-") end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Crafting over every known recipe with the latest AH view, spread over
-- frames (one recipe per step). A newer run cancels the one in progress.
-- Returns true when a run started. Bus: "crafting.updated"(crafting).
App.CRAFTING_KEEP = 10 -- rows per list kept in diagnostics

function App:EvaluateCrafting()
  local results = self.opportunities.results
  if not results or results.demo or ns.Data.Recipes.status ~= "observed" then return false end
  local work = self.craftWork
  work:Invalidate()
  local recipes = ns.Data.Recipes.List()
  local job = self:Timed("crafting_begin", #recipes, function() return self.opportunities:BeginCrafting(recipes) end)
  local startedAt = self.clock()
  self.craftingRunning = true
  work:Chunk(1, #recipes, self.store:Settings().frameBudgetMs, function(index)
    ns.Strategies.Crafting.RecipeStep(job, index)
  end, function(done, handle)
    if not done then return end
    self.craftingRunning = false
    self:ChunkTiming("crafting", handle, startedAt, function(index)
      local recipe = recipes[index]
      return recipe and ("r:" .. tostring(recipe.id)), recipe and #(recipe.reagents or {})
    end)
    local crafting = self.opportunities:FinishCrafting(job)
    -- The results may have been replaced by a newer evaluation meanwhile.
    local current = self.opportunities.results
    if current and not current.demo then current.crafting = crafting end
    self.lastCrafting = crafting
    self:RecordCrafting(crafting)
    self.bus:Publish("crafting.updated", crafting)
  end)
  return true
end

-- Compact copy of the best rows in ForeverGoldDB.diagnostics.crafting, to
-- check the evaluation against the game.
function App:RecordCrafting(crafting)
  local function rows(list)
    local out = {}
    for index = 1, math.min(#list, App.CRAFTING_KEEP) do
      local row = list[index]
      out[index] = { recipeID = row.recipeID, name = row.name, profession = row.profession, quantity = row.quantity,
        cost = row.cost, exit = row.exit, revenue = row.revenue, profit = row.profit, outputItemID = row.outputItemID,
        crafts = row.run and row.run.crafts, runCost = row.run and row.run.cost, runProfit = row.run and row.run.profit,
        runExit = row.run and row.run.exit, limit = row.run and row.run.limit }
    end
    return out
  end
  self.store.db.diagnostics.crafting = {
    at = crafting.at, counts = crafting.counts, excluded = crafting.excluded,
    learned = rows(crafting.learned), learnable = rows(crafting.learnable),
    totals = { learned = #crafting.learned, learnable = #crafting.learnable },
  }
end

-- Client events forwarded by Core/Init.
function App:OnEvent(event, ...)
  if not self.loaded then return end
  if event == "GET_ITEM_INFO_RECEIVED" then
    self.items:OnItemInfo(...)
  elseif event == "PLAYER_LOGOUT" then
    self.history:Prune(self.clock(), nil)
  elseif event == "PLAYER_MONEY" or event == "BAG_UPDATE_DELAYED" then
    self.feeTest:OnBagsOrMoney()
  elseif event == "MAIL_INBOX_UPDATE" then
    self.feeTest:OnInbox()
  elseif event == "MERCHANT_SHOW" then
    self.vendorCheck:OnMerchantShow()
    self:ObserveMerchantSoon()
  elseif event == "MERCHANT_UPDATE" then
    self:ObserveMerchantSoon()
  elseif event == "MERCHANT_CLOSED" then
    self.vendorCheck:OnMerchantClosed()
  elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_CLOSE" then
    self.diagnostics:Trace("tradeskill", { event = event })
    if event ~= "TRADE_SKILL_CLOSE" then self:ObserveProfessionSoon(event == "TRADE_SKILL_SHOW") end
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    self.autoScan:OnBlocked(event, ...)
  elseif event == "NEW_RECIPE_LEARNED" then
    self:OnRecipeLearned(...)
  else
    if event == "AUCTION_HOUSE_SHOW" then self.marketKeyCache = nil end
    self.ah:OnEvent(event, ...)
    if event == "AUCTION_HOUSE_SHOW" then
      self.autoScan:OnShow()
    elseif event == "AUCTION_HOUSE_CLOSED" then
      self.autoScan:OnClose()
    end
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
