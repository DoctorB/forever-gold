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
    commodity = deps.commodity, latest = {}, marketKey = nil, results = nil, lastNotify = 0,
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
function Opportunities:Ingest(snapshot, listings)
  if snapshot.marketKey ~= self.marketKey then
    self.latest = {}
    self.marketKey = snapshot.marketKey
  end
  local grouped = {}
  for _, listing in ipairs(listings) do
    local list = grouped[listing.itemKey]
    if not list then
      list = {}
      grouped[listing.itemKey] = list
    end
    list[#list + 1] = listing
  end
  if snapshot.mode == "replicate" then self.latest = {} end
  if snapshot.mode ~= "replicate" and snapshot.scope and not grouped[snapshot.scope] then
    -- Observation of an empty result: the item has no listing right now.
    self.latest[snapshot.scope] = nil
  end
  for itemKey, list in pairs(grouped) do
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

function Opportunities:EvaluateStep(job, index)
  local itemKey = job.keys[index]
  local view = self.latest[itemKey]
  if not view then return end
  local results, now, settings = job.results, job.now, job.settings
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
  Opportunities.Rank(results.list)
  Opportunities.Allocate(results.list, job.settings)
  results.counts.opportunities = #results.list
  self.results = results
  if self.bus then self.bus:Publish("opportunities.updated", results) end
  return results
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

-- Class first (confirmed vendor, prudent, speculative), then prudent profit.
function Opportunities.Rank(list)
  table.sort(list, function(a, b)
    local ca, cb = Risk.CLASS_ORDER[a.class] or 9, Risk.CLASS_ORDER[b.class] or 9
    if ca ~= cb then return ca < cb end
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
