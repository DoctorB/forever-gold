local ns = T.LoadAddon()
local Schema, Store, History = ns.Data.Schema, ns.Data.Store, ns.Data.History
local MarketValue = ns.Economy.MarketValue
local Disenchant, Crafting, Conversion = ns.Strategies.Disenchant, ns.Strategies.Crafting, ns.Strategies.Conversion
local Resale, Vendor = ns.Strategies.Resale, ns.Strategies.Vendor

local MARKET = Schema.MarketKey({ product = "p18", realm = "R", faction = "Alliance" })
local DAY = MarketValue.DAY

local function listing(itemID, quantity, total, index, extra)
  local raw = { marketKey = MARKET, itemKey = Schema.ItemKey(itemID, 0), quantity = quantity, buyoutTotal = total,
    divisible = false, source = "replicate", scanId = "s", index = index }
  for key, value in pairs(extra or {}) do raw[key] = value end
  return Schema.NewListing(raw)
end

T.Case("DE: 50% net 400, 50% net 800, cost 500 -> EV profit 100, loss probability 50%", function()
  local outcomes = { { p = 0.5, value = 400 }, { p = 0.5, value = 800 } }
  local scenario = Disenchant.Scenario(outcomes, 500, 1)
  T.Eq(scenario.evProfit, 100)
  T.Eq(scenario.lossProbability, 0.5)
  T.Eq(scenario.worst, -100)
  T.Eq(scenario.best, 300)
end)

T.Case("DE: purchase counted once over several items; small n keeps a real loss chance", function()
  local outcomes = { { p = 0.5, value = 400 }, { p = 0.5, value = 800 } }
  local scenario = Disenchant.Scenario(outcomes, 500, 2)
  T.Eq(scenario.evProfit, 200)
  T.Eq(scenario.lossProbability, 0.25)
  T.Eq(select(2, Disenchant.ExpectedValue({ { p = 0.6, value = 1 } })), "invalid_outcomes")
end)

T.Case("DE ranking disabled without a verified dataset", function()
  local list, excluded = Disenchant.Evaluate({})
  T.Eq(#list, 0)
  T.Eq(excluded.dataset_unavailable, 1)
end)

T.Case("crafting: 2 outputs per craft, need 3 -> 2 crafts, 4 outputs, reagents for 2", function()
  local recipe = { id = 1, outputs = { { itemID = 10, quantity = 2 } }, reagents = { { itemID = 20, quantity = 3 }, { itemID = 21, quantity = 1 } } }
  local plan = Crafting.Plan(recipe, 10, 3)
  T.Eq(plan.crafts, 2)
  T.Eq(plan.outputs, 4)
  T.Eq(plan.reagents[20], 6)
  T.Eq(plan.reagents[21], 2)
end)

T.Case("crafting: owned reagents are not free, reported apart", function()
  local recipe = { id = 1, outputs = { { itemID = 10, quantity = 1 } }, reagents = { { itemID = 20, quantity = 2 } } }
  local plan = Crafting.Plan(recipe, 10, 2)
  local market = { [20] = { levels = { { quantity = 10, unitPrice = 100, divisible = true } }, owned = 2, ownedValue = 90 } }
  local r = Crafting.Price(plan, market, 400, 0)
  T.Eq(r.moneyCost, 200)
  T.Eq(r.opportunityCost, 180)
  T.Eq(r.profit, 600)
  T.Eq(r.economicProfit, 420)
  T.Eq(select(2, Crafting.Price(plan, market, nil, 0)), "output_price_unknown")
end)

T.Case("conversion: a cycle stops and resources are never duplicated", function()
  local recipes = {
    { id = "AtoB", reagents = { { itemID = 1, quantity = 1 } }, outputs = { { itemID = 2, quantity = 1 } } },
    { id = "BtoA", reagents = { { itemID = 2, quantity = 1 } }, outputs = { { itemID = 1, quantity = 1 } } },
  }
  local market = {
    [1] = { levels = { { quantity = 5, unitPrice = 10, divisible = true } }, sellPrice = 10 },
    [2] = { sellPrice = 12 },
  }
  local result = Conversion.Plan(1, 5, recipes, market, 3)
  T.Ok(result.cyclesBlocked > 0, "cycle blocked")
  T.Eq(#result.best.path, 1)
  T.Eq(result.best.inventory[2], 5)
  T.Eq(result.best.inventory[1], nil)
  T.Eq(result.best.profit, 10)
  local total = 0
  for _, quantity in pairs(result.best.inventory) do total = total + quantity end
  T.Eq(total, 5, "units conserved")
end)

T.Case("conversion: finite start stock is respected", function()
  local market = { [1] = { levels = { { quantity = 2, unitPrice = 10, divisible = true } } } }
  T.Eq(select(2, Conversion.Plan(1, 5, {}, market)), "start_depth")
end)

local function seededHistory(prices, now)
  local store = Store.New(nil, { now = now })
  local history = History.New(store, function() return now end)
  for back, price in ipairs(prices) do
    local t = now - back * DAY
    history:Record({ id = "h" .. back, marketKey = MARKET, coverage = "full_unverified", finished = t },
      { listing(5, 100, price * 100, 1), listing(5, 100, price * 100, 2) })
  end
  return store, history
end

T.Case("resale: prudent opportunity ranked as speculative while the fee is a scenario", function()
  local now = 200 * DAY
  local _, history = seededHistory({ 1000, 1000, 1000, 1000, 1000, 1000, 1000 }, now)
  local itemKey = Schema.ItemKey(5, 0)
  local entry = {
    listings = { listing(5, 10, 3000, 1), listing(5, 10, 10000, 2), listing(5, 10, 10000, 3) },
    estimate = MarketValue.Estimate(history, itemKey, MARKET, now), depositPerUnit = 10,
  }
  local settings = { feeBp = 500, feeVerified = false, bufferBp = 500, minRoiBp = 1500, minProfit = 1000 }
  local list = Resale.Evaluate({ items = { [itemKey] = entry }, settings = settings, scan = { ageSeconds = 60, partial = true } })
  T.Eq(#list, 1)
  local o = list[1]
  T.Eq(o.class, "speculative")
  T.Eq(o.quantity, 10)
  T.Eq(o.cost, 3000)
  T.Ok(o.profit > 1000)
  T.Eq(o.formula.feeVerified, false)
  -- Units beyond liquidity are inventory, not profit.
  T.Eq(o.formula.sellUnits + o.formula.residualUnits, 10)
end)

T.Case("resale: insufficient history yields a scenario, not a ranked deal", function()
  local now = 200 * DAY
  local _, history = seededHistory({ 1000 }, now)
  local itemKey = Schema.ItemKey(5, 0)
  local entry = { listings = { listing(5, 10, 3000, 1) }, estimate = MarketValue.Estimate(history, itemKey, MARKET, now) }
  local list, excluded, scenarios = Resale.Evaluate({ items = { [itemKey] = entry }, settings = { feeBp = 500 } })
  T.Eq(#list, 0)
  T.Eq(excluded.insufficient_history, 1)
  T.Eq(scenarios[itemKey].lowest, 300)
end)

T.Case("resale: unknown variant is excluded", function()
  local key = Schema.ItemKey(5, nil, true)
  local _, excluded = Resale.Evaluate({ items = { [key] = { listings = {} } }, settings = { feeBp = 500 } })
  T.Eq(excluded.variant_unknown, 1)
end)

T.Case("resale: a single very high competitor does not create a deal", function()
  local now = 200 * DAY
  local _, history = seededHistory({ 300, 300, 300, 300, 300, 300, 300 }, now)
  local itemKey = Schema.ItemKey(5, 0)
  local entry = {
    listings = { listing(5, 10, 3000, 1), listing(5, 1, 900000, 2) },
    estimate = MarketValue.Estimate(history, itemKey, MARKET, now),
  }
  local list = Resale.Evaluate({ items = { [itemKey] = entry }, settings = { feeBp = 500, minRoiBp = 1500, minProfit = 1000 } })
  T.Eq(#list, 0)
end)

T.Case("vendor: unknown sell price is excluded and counted", function()
  local entry = { listings = { listing(7, 1, 10, 1) }, info = nil }
  local list, excluded = Vendor.Evaluate({ items = { k = entry }, settings = {} })
  T.Eq(#list, 0)
  T.Eq(excluded.sell_price_unknown, 1)
end)
