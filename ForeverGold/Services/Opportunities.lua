-- Opportunities: keeps the latest normalized listings per item key, runs the
-- strategies, ranks and allocates. Always reports its denominators: item
-- keys, listing rows, units, candidates and opportunities, plus coverage.
local _, ns = ...

local Money = ns.Economy.Money
local MarketValue = ns.Economy.MarketValue
local Risk = ns.Economy.Risk
local Schema = ns.Data.Schema
local Capabilities = ns.Core.Capabilities
local Opportunities = {}
ns.Services.Opportunities = Opportunities

-- deps: { store, history, items (ItemProvider), clock, bus, commodity?(itemID) -> true/false/nil }
function Opportunities.New(deps)
  local self = setmetatable({
    store = deps.store, history = deps.history, items = deps.items, clock = deps.clock, bus = deps.bus,
    commodity = deps.commodity, merchantPrice = deps.merchantPrice, depositVerified = deps.depositVerified,
    ownedCount = deps.ownedCount, sales = deps.sales, -- sales: Services/SellThrough or nil
    latest = {}, marketKey = nil, results = nil, lastNotify = 0,
    stale = {}, -- itemID -> true: a purchase attempt found the offer gone
  }, { __index = Opportunities })
  return self
end

-- Commodity rows of the replicate become divisible levels: a commodity can
-- be bought in part at its unit price. Only exact totals are converted
-- (verified in game: replicate buyouts are unit price x count).
function Opportunities.CommodityLevels(listings)
  local levels = {}
  for _, listing in ipairs(listings) do
    if listing.buyable and not listing.divisible and listing.buyoutTotal % listing.quantity == 0 then
      local copy = {}
      for key, value in pairs(listing) do copy[key] = value end
      copy.divisible, copy.unitPrice = true, listing.buyoutTotal / listing.quantity
      levels[#levels + 1] = copy
    else
      levels[#levels + 1] = listing
    end
  end
  return levels
end

local function semanticsVerified(source)
  if source == "replicate" then return Capabilities.IsVerified("replicateBuyoutIsTotal") end
  if source == "search_commodity" then return Capabilities.IsVerified("commoditySearch") end
  if source == "search_item" then return Capabilities.IsVerified("itemSearch") end
  return false
end

-- Applies a finished snapshot: a replicate replaces the whole market view,
-- an observation replaces one item key.
-- Ingest in steps: BeginIngest, IngestListing per listing (spread over
-- frames by the client), FinishIngest applies the result in one go.
function Opportunities.BeginIngest(snapshot)
  return { snapshot = snapshot, grouped = {} }
end

function Opportunities.IngestListing(job, listing)
  local list = job.grouped[listing.itemKey]
  if not list then
    list = {}
    job.grouped[listing.itemKey] = list
  end
  list[#list + 1] = listing
end

function Opportunities:Ingest(snapshot, listings)
  local job = Opportunities.BeginIngest(snapshot)
  for _, listing in ipairs(listings) do Opportunities.IngestListing(job, listing) end
  self:FinishIngest(job)
end

function Opportunities:FinishIngest(job)
  local snapshot, grouped = job.snapshot, job.grouped
  if snapshot.marketKey ~= self.marketKey then
    self.latest = {}
    self.marketKey = snapshot.marketKey
  end
  if snapshot.mode == "replicate" then
    self.latest = {}
    self.stale = {}
  end
  if snapshot.mode ~= "replicate" and snapshot.scope and not grouped[snapshot.scope] then
    -- Observation of an empty result: the item has no listing right now.
    self.latest[snapshot.scope] = nil
  end
  for itemKey, list in pairs(grouped) do
    -- Only a full scan clears "gone" marks (above): in game a late duplicate
    -- answer to a purchase search, read as an own search, cleared it and the
    -- same gone lot was tried again 11 s later (2026-11-07 23:47).
    self.latest[itemKey] = {
      listings = list, seen = snapshot.finished, coverage = snapshot.coverage, mode = snapshot.mode,
      scanId = snapshot.id, source = list[1].source,
    }
  end
  self.lastSnapshot = snapshot
end

local function count(tally, reasons)
  for reason, n in pairs(reasons or {}) do tally[reason] = (tally[reason] or 0) + n end
end

-- Evaluation runs in steps (one item key each) so the client can spread it
-- over frames; Evaluate runs all steps at once.
function Opportunities:BeginEvaluate()
  local job = {
    now = self.clock(), settings = self.store:Settings(), keys = {},
    strategies = { ns.Strategies.Vendor, ns.Strategies.Resale },
    results = {
      marketKey = self.marketKey, list = {}, excluded = {}, scenarios = {},
      counts = { itemKeys = 0, listings = 0, units = 0, candidates = 0, opportunities = 0, infoPending = 0 },
      coverage = self.lastSnapshot and self.lastSnapshot.coverage or "none",
      snapshot = self.lastSnapshot,
    },
  }
  job.results.at = job.now
  for itemKey in pairs(self.latest) do job.keys[#job.keys + 1] = itemKey end
  table.sort(job.keys)
  return job
end

-- A purchase attempt showed the offer is gone or dearer: hide it until
-- fresh data for the item arrives (next scan or a manual search).
function Opportunities:MarkStale(itemID)
  if itemID then self.stale[itemID] = true end
end

function Opportunities:EvaluateStep(job, index)
  local itemKey = job.keys[index]
  local view = self.latest[itemKey]
  if not view then return end
  local results, now, settings = job.results, job.now, job.settings
  if self.stale[Schema.ItemIDOf(itemKey) or 0] then
    results.excluded.stale = (results.excluded.stale or 0) + 1
    return
  end
  results.counts.itemKeys = results.counts.itemKeys + 1
  results.counts.listings = results.counts.listings + #view.listings
  local buyable = 0
  for _, listing in ipairs(view.listings) do
    results.counts.units = results.counts.units + listing.quantity
    if listing.buyable then buyable = buyable + 1 end
  end
  if buyable > 0 then results.counts.candidates = results.counts.candidates + 1 end
  local itemID = Schema.ItemIDOf(itemKey)
  local info = self.items and self.items:Read(itemID)
  if not info and self.items then
    results.counts.infoPending = results.counts.infoPending + 1
    -- Arrival is announced by the provider (App publishes "items.resolved").
    self.items:Resolve(itemID, function() end)
  end
  local commodity
  if view.source == "search_commodity" then
    commodity = true
  elseif self.commodity and itemID then
    commodity = self.commodity(itemID)
    if commodity == nil then results.counts.commodityPending = (results.counts.commodityPending or 0) + 1 end
  end
  local listings = view.listings
  if commodity == true and view.source == "replicate" then listings = Opportunities.CommodityLevels(listings) end
  local entry = {
    listings = listings, info = info, commodity = commodity,
    estimate = MarketValue.Estimate(self.history, itemKey, self.marketKey, now, { bufferBp = settings.bufferBp }),
    depositFor = Opportunities.DepositFor(info and info.sellPrice, commodity, info and info.stackCount),
    depositVerified = self.depositVerified and self.depositVerified() or false,
    sales = self.sales and self.sales:Stats(itemKey) or nil,
  }
  local context = {
    items = { [itemKey] = entry }, settings = settings,
    scan = {
      ageSeconds = view.seen and (now - view.seen) or nil, partial = view.coverage ~= "full_verified",
      mode = view.mode, id = view.scanId, finished = view.seen,
    },
    semantics = {
      buyoutVerified = semanticsVerified(view.source), sellPriceVerified = Capabilities.IsVerified("sellPrice"),
    },
  }
  for _, strategy in ipairs(job.strategies) do
    local found, excluded, scenarios = strategy.Evaluate(context)
    count(results.excluded, excluded)
    for key, scenario in pairs(scenarios or {}) do results.scenarios[key] = scenario end
    for _, opportunity in ipairs(found) do
      opportunity.coverage = view.coverage
      opportunity.category = info and info.classID
      opportunity.commodity = commodity
      opportunity.itemID = itemID
      opportunity.sellPrice = info and info.sellPrice
      results.list[#results.list + 1] = opportunity
    end
  end
end

function Opportunities:FinishEvaluate(job)
  local results = job.results
  results.list = Opportunities.MergeVendor(results.list, job.settings, results.excluded)
  if self.sales then
    local snapshot = self.lastSnapshot
    local full = snapshot ~= nil and snapshot.mode == "replicate"
    self.sales:MarkPersisted(results.list, full and snapshot.finished or nil, full)
  end
  Opportunities.Rank(results.list)
  Opportunities.Allocate(results.list, job.settings)
  results.counts.opportunities = #results.list
  self.results = results
  if self.bus then self.bus:Publish("opportunities.updated", results) end
  return results
end

-- Crafting over the given recipes with the latest AH view. Only the item
-- keys of the recipes' reagents and outputs are touched; variants of one
-- item are merged (their books are bought from together).
Opportunities.MERCHANT_UNITS = 1000000 -- "unlimited" merchant supply

-- Deposit for selling `units` of an item (8 h), from its merchant price, or
-- nil when the merchant price is unknown or zero.
function Opportunities.DepositFor(sellPrice, commodity, stackSize)
  if type(sellPrice) ~= "number" or sellPrice <= 0 then return nil end
  return function(units)
    return ns.Economy.Deposit.ForUnits(sellPrice, units, commodity == true, nil, stackSize)
  end
end

-- Stepwise form: BeginCrafting, then ns.Strategies.Crafting.RecipeStep(job,
-- index) for each recipe, then FinishCrafting(job).
function Opportunities:BeginCrafting(recipes, skills)
  local settings = self.store:Settings()
  local wanted = {}
  for _, recipe in ipairs(recipes) do
    for _, reagent in ipairs(recipe.reagents or {}) do wanted[reagent.itemID] = true end
    for _, output in ipairs(recipe.outputs or {}) do wanted[output.itemID] = true end
  end
  local keysByItem = {}
  for itemKey in pairs(self.latest) do
    local itemID = Schema.ItemIDOf(itemKey)
    if itemID and wanted[itemID] and not self.stale[itemID] then
      local keys = keysByItem[itemID] or {}
      keysByItem[itemID] = keys
      keys[#keys + 1] = itemKey
    end
  end
  local now, cache, pending = self.clock(), {}, 0
  local function market(itemID)
    local entry = cache[itemID]
    if entry then return entry end
    entry = { levels = {} }
    local keys = keysByItem[itemID] or {}
    table.sort(keys)
    for _, itemKey in ipairs(keys) do
      local view = self.latest[itemKey]
      local listings = view.listings
      local commodity = view.source == "search_commodity" or (self.commodity and self.commodity(itemID))
      if commodity == true and view.source == "replicate" then listings = Opportunities.CommodityLevels(listings) end
      for _, listing in ipairs(listings) do entry.levels[#entry.levels + 1] = listing end
      if not entry.estimate then
        local estimate = MarketValue.Estimate(self.history, itemKey, self.marketKey, now, { bufferBp = settings.bufferBp })
        if estimate.status == "ok" then entry.estimate = estimate end
      end
      if not entry.sales and self.sales then entry.sales = self.sales:Stats(itemKey) end
    end
    -- A merchant sells any quantity at its price: one more divisible
    -- level, bought from only when it is the cheapest. Not part of the
    -- AH competition (entry.book counts AH listings only).
    local merchantUnit = self.merchantPrice and self.merchantPrice(itemID)
    if merchantUnit then
      entry.merchantUnit = merchantUnit
      entry.reagentLevels = { { quantity = Opportunities.MERCHANT_UNITS, unitPrice = merchantUnit, divisible = true,
        buyable = true, merchant = true, id = "merchant:" .. itemID } }
      for _, level in ipairs(entry.levels) do entry.reagentLevels[#entry.reagentLevels + 1] = level end
    end
    local info = self.items and self.items:Read(itemID)
    if info then
      entry.sellPrice, entry.bound, entry.name = info.sellPrice, info.bindType == 1, info.name
      entry.depositFor = Opportunities.DepositFor(info.sellPrice, self.commodity and self.commodity(itemID), info.stackCount)
    elseif self.items then
      pending = pending + 1
      self.items:Resolve(itemID, function() end)
    end
    cache[itemID] = entry
    return entry
  end
  -- Bag counts read once per run (they do not change while pricing).
  local owned = {}
  local ownedCount = self.ownedCount and function(itemID)
    if owned[itemID] == nil then owned[itemID] = self.ownedCount(itemID) or 0 end
    return owned[itemID]
  end
  local job = ns.Strategies.Crafting.BeginRecipes(recipes, market, settings, ownedCount, skills)
  job.pending = function() return pending end
  job.at = now
  return job
end

function Opportunities:FinishCrafting(job)
  local result = ns.Strategies.Crafting.FinishRecipes(job)
  result.counts.infoPending = job.pending()
  result.at = job.at
  return result
end

-- All recipes in one go (offline and tests).
function Opportunities:EvaluateCrafting(recipes, skills)
  local job = self:BeginCrafting(recipes, skills)
  for index = 1, #recipes do ns.Strategies.Crafting.RecipeStep(job, index) end
  return self:FinishCrafting(job)
end

-- Runs every enabled strategy at once. Returns the results table (also kept).
function Opportunities:Evaluate()
  local job = self:BeginEvaluate()
  for index = 1, #job.keys do self:EvaluateStep(job, index) end
  return self:FinishEvaluate(job)
end

-- Removes what an assisted purchase bought from the latest view, so the
-- opportunity does not reappear before the next scan.
function Opportunities:Consume(plan, auction)
  local view = self.latest[plan.itemKey]
  if not view then return end
  local listings = view.listings
  if plan.kind == "commodity" then
    local order = {}
    for index, listing in ipairs(listings) do
      if listing.buyable then order[#order + 1] = index end
    end
    table.sort(order, function(a, b)
      local la, lb = listings[a], listings[b]
      return la.buyoutTotal * lb.quantity < lb.buyoutTotal * la.quantity
    end)
    local left = plan.quantity
    for _, index in ipairs(order) do
      if left <= 0 then break end
      local listing = listings[index]
      local unit = listing.buyoutTotal / listing.quantity
      local take = math.min(left, listing.quantity)
      listing.quantity = listing.quantity - take
      listing.buyoutTotal = unit * listing.quantity
      listing.unitPrice = listing.quantity > 0 and Money.DivCeil(listing.buyoutTotal, listing.quantity) or nil
      listing.buyable = listing.quantity > 0
      left = left - take
    end
  else
    for index, listing in ipairs(listings) do
      if listing.buyable and listing.quantity == plan.lot.quantity
        and listing.buyoutTotal <= (auction and auction.amount or plan.lot.buyoutTotal) then
        table.remove(listings, index)
        break
      end
    end
  end
  local kept = {}
  for _, listing in ipairs(listings) do
    if listing.quantity > 0 then kept[#kept + 1] = listing end
  end
  view.listings = kept
end

-- One vendor row per item: variants of the same item (bonus IDs) share the
-- merchant price, so their lots are merged; then the vendor thresholds
-- apply to the merged totals. Each lot keeps its own listing and item key.
function Opportunities.MergeVendor(list, settings, excluded)
  local out, byItem = {}, {}
  for _, o in ipairs(list) do
    local merged = o.strategy == "vendor" and o.itemID and byItem[o.itemID]
    if merged then
      for _, lot in ipairs(o.lots) do merged.lots[#merged.lots + 1] = lot end
      merged.quantity = merged.quantity + o.quantity
      merged.cost = merged.cost + o.cost
      merged.capital = merged.capital + o.capital
      merged.revenuePrudent = merged.revenuePrudent + o.revenuePrudent
      merged.revenueBase = merged.revenueBase + o.revenueBase
      merged.profit = merged.profit + o.profit
      merged.variants = merged.variants + 1
      merged.formula.units, merged.formula.B = merged.quantity, merged.cost
    else
      if o.strategy == "vendor" and o.itemID then
        local lots = {}
        for index, lot in ipairs(o.lots) do lots[index] = lot end
        o.lots, o.variants = lots, 1
        byItem[o.itemID] = o
      end
      out[#out + 1] = o
    end
  end
  local kept = {}
  local minProfit, minRoiBp = settings.minVendorProfit or 1, settings.minVendorRoiBp or 0
  for _, o in ipairs(out) do
    if o.strategy == "vendor" then
      o.roi = o.cost > 0 and o.profit / o.cost or nil
      if o.profit < minProfit or (o.roi or 0) * Money.BP < minRoiBp then
        excluded.below_threshold = (excluded.below_threshold or 0) + 1
      else
        kept[#kept + 1] = o
      end
    else
      kept[#kept + 1] = o
    end
  end
  return kept
end

-- Class first (confirmed vendor, prudent, speculative), then offers still
-- there after a scan interval (SellThrough:MarkPersisted), then prudent profit.
function Opportunities.Rank(list)
  table.sort(list, function(a, b)
    local ca, cb = Risk.CLASS_ORDER[a.class] or 9, Risk.CLASS_ORDER[b.class] or 9
    if ca ~= cb then return ca < cb end
    local pa, pb = (a.persisted or 0) > 0, (b.persisted or 0) > 0
    if pa ~= pb then return pa end
    if a.profit ~= b.profit then return a.profit > b.profit end
    return tostring(a.itemKey) < tostring(b.itemKey)
  end)
  return list
end

-- Budget allocation with reserve and per-item / per-category caps.
-- Marks each opportunity with allocation = "allocated" | reason.
function Opportunities.Allocate(list, settings)
  local budget = settings.budget
  if not Money.IsCopper(budget) or budget == 0 then
    for _, opportunity in ipairs(list) do opportunity.allocation = "no_budget" end
    return
  end
  local available = budget - Money.ShareUp(budget, settings.reserveBp or 0)
  local itemCap = Money.ShareDown(budget, settings.maxItemBp or Money.BP)
  local categoryCap = Money.ShareDown(budget, settings.maxCategoryBp or Money.BP)
  local perItem, perCategory = {}, {}
  for _, opportunity in ipairs(list) do
    local cost = opportunity.capital or opportunity.cost
    local category = opportunity.category or "?"
    local itemUsed = perItem[opportunity.itemKey] or 0
    local categoryUsed = perCategory[category] or 0
    if cost > available then
      opportunity.allocation = "over_budget"
    elseif itemUsed + cost > itemCap then
      opportunity.allocation = "item_cap"
    elseif categoryUsed + cost > categoryCap then
      opportunity.allocation = "category_cap"
    else
      opportunity.allocation = "allocated"
      available = available - cost
      perItem[opportunity.itemKey] = itemUsed + cost
      perCategory[category] = categoryUsed + cost
    end
  end
end

-- One aggregated local notice, with threshold and cooldown; never per row.
function Opportunities:NotifyIfDue(printer)
  local settings = self.store:Settings()
  local results = self.results
  if not settings.notify or not results then return false end
  local now = self.clock()
  if now - self.lastNotify < (settings.notifyCooldown or 300) then return false end
  local good = 0
  for _, opportunity in ipairs(results.list) do
    if opportunity.class ~= "speculative" then good = good + 1 end
  end
  if good == 0 then return false end
  self.lastNotify = now
  printer(good, results.counts)
  return true
end
