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

-- Reagents made by the player (crafting chains). Market: ore 30 each on the
-- AH (commodity), the bar sold on the AH at 200+ (3 listings), the grinding
-- stone nowhere.
local function chainMarket(itemID)
  if itemID == 102 then return { levels = { { quantity = 100, unitPrice = 30, divisible = true, buyable = true } } } end
  if itemID == 301 then
    local levels = {}
    for index = 1, 3 do levels[index] = { quantity = 1, buyoutTotal = 190 + index * 10, divisible = false, buyable = true } end
    return { levels = levels, sellPrice = 10 }
  end
  return { levels = {}, sellPrice = 0 }
end
local CHAIN_SETTINGS = { feeBp = 500, bufferBp = 500 }

T.Case("crafting chain: a reagent nobody sells is costed by the recipe that makes it", function()
  local ns = T.LoadAddon()
  local Crafting = ns.Strategies.Crafting
  local recipes = {
    { id = 5, name = "Grinding Stone", learned = true, outputs = { { itemID = 778, quantity = 1 } },
      reagents = { { itemID = 102, quantity = 2 } } },
    { id = 6, name = "Sword", learned = true, outputs = { { itemID = 301, quantity = 1 } },
      reagents = { { itemID = 778, quantity = 1 }, { itemID = 102, quantity = 1 } } },
  }
  local result = Crafting.EvaluateRecipes(recipes, chainMarket, CHAIN_SETTINGS)
  T.Eq(#result.learned, 1, "the stone has no value of its own; the sword is priced")
  local sword = result.learned[1]
  -- Stone: 2 ore = 60; sword: 60 + 30 = 90; bar 200 - 5% = 190, - 5% fee = 180.
  T.Eq(sword.cost, 90)
  T.Eq(sword.profit, 90)
  T.Eq(sword.reagents[1].crafted.name, "Grinding Stone")
  T.Eq(sword.reagents[1].crafted.learned, true)
  T.Eq(sword.alsoLearn, nil)
end)

T.Case("crafting chain: an unknown step moves the result to the learnable list", function()
  local ns = T.LoadAddon()
  local Crafting = ns.Strategies.Crafting
  local recipes = {
    { id = 5, name = "Grinding Stone", learned = false, outputs = { { itemID = 778, quantity = 2 } },
      reagents = { { itemID = 102, quantity = 2 } } },
    { id = 6, name = "Sword", learned = true, outputs = { { itemID = 301, quantity = 1 } },
      reagents = { { itemID = 778, quantity = 3 } } },
  }
  local result = Crafting.EvaluateRecipes(recipes, chainMarket, CHAIN_SETTINGS)
  T.Eq(#result.learned, 0)
  local sword = result.learnable[1]
  T.Ok(sword, "priced as learnable")
  -- 3 stones need 2 crafts of 2 (whole crafts): 4 ore = 120.
  T.Eq(sword.reagents[1].crafted.crafts, 2)
  T.Eq(sword.cost, 120)
  T.Eq(sword.profit, 60)
  T.Eq(sword.alsoLearn[1], "Grinding Stone")
end)

T.Case("crafting chain: cycles and long chains stop, the recipe stays unpriced", function()
  local ns = T.LoadAddon()
  local Crafting = ns.Strategies.Crafting
  local recipes = {
    { id = 1, name = "A from B", learned = true, outputs = { { itemID = 801, quantity = 1 } }, reagents = { { itemID = 802, quantity = 1 } } },
    { id = 2, name = "B from A", learned = true, outputs = { { itemID = 802, quantity = 1 } }, reagents = { { itemID = 801, quantity = 1 } } },
    { id = 3, name = "Sword from A", learned = true, outputs = { { itemID = 301, quantity = 1 } }, reagents = { { itemID = 801, quantity = 1 } } },
    -- Four levels deep: 901 <- 902 <- 903 <- 904 <- ore.
    { id = 11, learned = true, outputs = { { itemID = 904, quantity = 1 } }, reagents = { { itemID = 102, quantity = 1 } } },
    { id = 12, learned = true, outputs = { { itemID = 903, quantity = 1 } }, reagents = { { itemID = 904, quantity = 1 } } },
    { id = 13, learned = true, outputs = { { itemID = 902, quantity = 1 } }, reagents = { { itemID = 903, quantity = 1 } } },
    { id = 14, name = "Deep", learned = true, outputs = { { itemID = 301, quantity = 1 } }, reagents = { { itemID = 902, quantity = 1 } } },
  }
  local result = Crafting.EvaluateRecipes(recipes, chainMarket, CHAIN_SETTINGS)
  for _, row in ipairs(result.learned) do
    T.NotOk(row.recipeID == 3, "no price from a cycle")
  end
  local deep
  for _, row in ipairs(result.learned) do if row.recipeID == 14 then deep = row end end
  T.Ok(deep, "three levels are allowed (902 <- 903 <- 904 <- ore)")
  T.Ok(result.excluded.reagent_not_on_ah >= 1)
end)
