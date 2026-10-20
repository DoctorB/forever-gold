-- Deterministic cases from the spec (section 13) and economic properties.
local ns = T.LoadAddon()
local Money, Depth, Costs = ns.Economy.Money, ns.Economy.Depth, ns.Economy.Costs
local MarketValue, Risk = ns.Economy.MarketValue, ns.Economy.Risk
local Schema, Vendor = ns.Data.Schema, ns.Strategies.Vendor

local MARKET = Schema.MarketKey({ product = "p18", region = 3, realm = "R", faction = "Alliance" })

local function listing(itemID, quantity, total, index)
  return Schema.NewListing({ marketKey = MARKET, itemKey = Schema.ItemKey(itemID, 0), quantity = quantity,
    buyoutTotal = total, divisible = false, source = "replicate", scanId = "s", index = index })
end

T.Case("vendor: 20 units x 50 copper for buyout 700 -> margin 300, no resale fee", function()
  T.Eq(Vendor.LotProfit(20, 700, 50), 300)
  local opportunities = Vendor.Evaluate({
    items = { [Schema.ItemKey(1, 0)] = { listings = { listing(1, 20, 700, 1) }, info = { sellPrice = 50, name = "x" } } },
    settings = { feeBp = 500 },
  })
  T.Eq(#opportunities, 1)
  T.Eq(opportunities[1].profit, 300)
  T.Eq(opportunities[1].fee, 0)
end)

T.Case("buyout total 10000 for 20 units -> unit 500, no double multiplication", function()
  local l = listing(1, 20, 10000, 1)
  T.Eq(l.unitPrice, 500)
  T.Eq(l.buyoutTotal, 10000)
  local purchase = Depth.BuyCost({ l }, 20)
  T.Eq(purchase.cost, 10000)
end)

T.Case("depth: 2 units at 100 and 3 at 200, buying 4 costs 600 not 400", function()
  local levels = {
    { quantity = 2, unitPrice = 100, divisible = true },
    { quantity = 3, unitPrice = 200, divisible = true },
  }
  local purchase = Depth.BuyCost(levels, 4)
  T.Eq(purchase.cost, 600)
  T.Eq(purchase.quantity, 4)
  T.Ok(purchase.complete)
  T.NotOk(Depth.BuyCost(levels, 6).complete, "only 5 units exist")
end)

T.Case("indivisible lots are bought whole", function()
  local purchase = Depth.BuyCost({ listing(1, 5, 500, 1), listing(1, 10, 2000, 2) }, 6)
  T.Eq(purchase.quantity, 15)
  T.Eq(purchase.cost, 2500)
end)

T.Case("spec 8 example: B=10000 R=12000 f=5% L=500 X=0", function()
  local r = Costs.Evaluate({ B = 10000, R = 12000, feeBp = 500, L = 500, X = 0 })
  T.Eq(r.profit, 900)
  T.Eq(r.roi, 0.09)
  T.Eq(r.breakEven, 11053)
  T.Eq(Costs.NetRevenue(11053, 500) >= 10500, true)
  T.Ok(Costs.NetRevenue(11052, 500) < 10500, "one copper less does not break even")
end)

T.Case("unknown price or fee gives no number", function()
  T.Eq(Costs.Evaluate({ B = nil, R = 1, feeBp = 0, L = 0, X = 0 }), nil)
  T.Eq(select(2, Costs.Evaluate({ B = 1, R = 2, feeBp = nil, L = 0, X = 0 })), "fee_unknown")
  T.Eq(select(2, Costs.Evaluate({ B = 1, R = 2, feeBp = 0, L = nil, X = 0 })), "deposit_loss_unknown")
  T.Eq(select(2, Vendor.LotProfit(20, 700, nil)), "sell_price_unknown")
end)

T.Case("refunded deposit is capital, lost deposit is cost", function()
  local refunded = Costs.Deposit(300, true)
  local lost = Costs.Deposit(300, false)
  T.Eq(refunded.capital, 300)
  T.Eq(refunded.cost, 0)
  local a = Costs.Evaluate({ B = 1000, R = 2000, feeBp = 0, L = refunded.cost, X = 0 })
  local b = Costs.Evaluate({ B = 1000, R = 2000, feeBp = 0, L = lost.cost, X = 0 })
  T.Eq(a.profit, 1000)
  T.Eq(b.profit, 700)
end)

T.Case("property: buying more never costs less", function()
  local levels = { listing(1, 3, 150, 1), listing(1, 1, 80, 2), listing(1, 7, 700, 3),
    { quantity = 4, unitPrice = 60, divisible = true } }
  local previous = 0
  for q = 1, Depth.Available(levels) do
    local purchase = Depth.BuyCost(levels, q)
    T.Ok(purchase.cost >= previous, "q=" .. q)
    previous = purchase.cost
  end
end)

T.Case("property: higher fee never raises profit", function()
  local previous
  for fee = 0, 9000, 250 do
    local r = Costs.Evaluate({ B = 5000, R = 9000, feeBp = fee, L = 100, X = 50 })
    if previous then T.Ok(r.profit <= previous, "fee=" .. fee) end
    previous = r.profit
  end
end)

T.Case("property: vendor result does not depend on the AH fee", function()
  local entry = { listings = { listing(1, 20, 700, 1) }, info = { sellPrice = 50 } }
  local a = Vendor.Evaluate({ items = { k = entry }, settings = { feeBp = 0 } })
  local b = Vendor.Evaluate({ items = { k = entry }, settings = { feeBp = 1500 } })
  T.Eq(a[1].profit, b[1].profit)
end)

T.Case("listing without buyout or own is never buyable", function()
  local noBuyout = listing(1, 1, nil, 1)
  T.NotOk(noBuyout.buyable)
  local own = Schema.NewListing({ marketKey = MARKET, itemKey = "i:1:0", quantity = 1, buyoutTotal = 10, own = true })
  T.NotOk(own.buyable)
  T.Eq(Depth.BuyCost({ noBuyout, own }, 1).complete, false)
end)

T.Case("interval price: a mountain of high asks does not set the value", function()
  local listings = {}
  for index = 1, 10 do listings[#listings + 1] = listing(1, 20, 2000, index) end -- 100 each
  for index = 11, 20 do listings[#listings + 1] = listing(1, 200, 20000000, index) end -- 100000 each, huge stacks
  local interval = MarketValue.IntervalPrice(listings)
  T.Eq(interval.min, 100)
  T.Eq(interval.price, 100, "capped weight: big stacks of high asks do not dominate")
  T.Eq(interval.depth, 2200)
  local cheapMajority = { listing(1, 5, 500, 1), listing(1, 5, 500, 2), listing(1, 5, 550, 3), listing(1, 1, 99999, 4) }
  T.Eq(MarketValue.IntervalPrice(cheapMajority).price, 100)
end)

T.Case("estimate needs independent days; cold start stays insufficient", function()
  local day = MarketValue.DAY
  local now = 100 * day
  local two = { { day = 99, price = 100, depth = 10 }, { day = 98, price = 110, depth = 10 } }
  T.Eq(MarketValue.EstimateSeries(two, now).status, "insufficient_history")
  local five = { { day = 99, price = 100, depth = 10 }, { day = 98, price = 110, depth = 10 },
    { day = 97, price = 90, depth = 10 }, { day = 96, price = 300, depth = 10 }, { day = 95, price = 105, depth = 10 } }
  local estimate = MarketValue.EstimateSeries(five, now)
  T.Eq(estimate.status, "ok")
  T.Eq(estimate.window, 7)
  T.Eq(estimate.reference, 105)
end)

T.Case("prudent resale: min of history and competition, minus buffer, limited quantity", function()
  local estimate = { status = "ok", reference = 1000, typicalDepth = 20 }
  local remaining = { { quantity = 5, unitPrice = 900, divisible = true } }
  local p = MarketValue.PrudentResale({ estimate = estimate, remaining = remaining, units = 10, bufferBp = 500 })
  T.Eq(p.basePrice, 900)
  T.Eq(p.unitPrice, 855)
  T.Eq(p.sellUnits, 4) -- 20% of typical depth 20
  T.Eq(p.residualUnits, 6)
  T.Eq(p.prudentGross, 3420)
  T.Eq(select(2, MarketValue.PrudentResale({ estimate = { status = "insufficient_history" }, units = 1 })), "insufficient_history")
end)

T.Case("partial scan never raises confidence", function()
  local full = Risk.Confidence({ ageSeconds = 10, partial = false, semanticsVerified = true })
  local partial = Risk.Confidence({ ageSeconds = 10, partial = true, semanticsVerified = true })
  T.Ok(partial.score < full.score)
  local unknownAge = Risk.Confidence({ partial = false, semanticsVerified = true })
  T.Ok(unknownAge.score < full.score)
end)

T.Case("hard gates fail on unknown", function()
  local ok, failed = Risk.Gates({ priceValid = true, marketKnown = true, variantKnown = nil,
    quantityAvailable = true, requirementsMet = true, operationAllowed = true })
  T.NotOk(ok)
  T.Eq(failed[1], "variantKnown")
end)
