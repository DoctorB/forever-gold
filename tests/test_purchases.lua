-- Assisted buying and the vendor check on a fake client. The fake proves our
-- state machine and safety rules, not the real server's behaviour.
local ITEMS = {
  [101] = { name = "Linen", sellPrice = 50 },
  [201] = { name = "Green Sword", sellPrice = 300, classID = 2 },
}

local function setup(options)
  options = options or {}
  local wallet = { money = options.money or 9676 }
  local bags = options.bags or {}
  local rows = options.rows or {
    { itemID = 101, count = 20, buyout = 700 }, -- 35 each
    { itemID = 101, count = 10, buyout = 400 }, -- 40 each
    { itemID = 101, count = 5, buyout = 300 }, -- 60 each: above the vendor price
  }
  local app, ns, clock, ah = Fakes.App({ rows = rows, items = ITEMS, wallet = wallet, bags = bags })
  ah.commodityItems[101] = options.commodity101 ~= false and true or false
  ah.commodityItems[201] = false
  app.store:Settings().assistedBuy = true
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(60)
  local function find(itemID)
    for _, o in ipairs(app.opportunities.results.list) do
      if o.itemID == itemID then return o end
    end
  end
  return { app = app, ns = ns, clock = clock, ah = ah, wallet = wallet, bags = bags, find = find }
end

T.Case("commodities are recognised and bought in part at the unit price", function()
  local s = setup()
  local o = s.find(101)
  T.Ok(o, "vendor opportunity")
  T.Eq(o.commodity, true)
  T.Eq(o.quantity, 30)
  T.Eq(o.cost, 1100)
  T.Eq(o.profit, 400)
  T.Ok(o.lots[1].listing.divisible)
end)

T.Case("commodity status arriving later triggers a re-evaluation", function()
  local s = setup({ commodity101 = false })
  s.ah.commodityItems[101] = nil
  s.app.ah.commodity[101] = nil
  s.app:EvaluateChunked()
  s.clock.advance(5)
  T.Eq(s.app.opportunities.results.counts.commodityPending, 1)
  s.ah.commodityItems[101] = true
  s.app:OnEvent("ITEM_KEY_ITEM_INFO_RECEIVED", 101)
  s.clock.advance(5)
  T.Eq(s.find(101).commodity, true)
end)

T.Case("plan stays within the cap and the player's gold", function()
  local s = setup()
  local Purchases = s.ns.Services.Purchases
  local o = s.find(101)
  local plan = Purchases.Plan(o, 900, nil)
  T.Eq(plan.kind, "commodity")
  T.Eq(plan.quantity, 25) -- 20 at 35 + 5 at 40
  T.Eq(plan.expectedTotal, 900)
  T.Eq(Purchases.Plan(o, 9676, 500).quantity, 14)
  T.Eq(select(2, Purchases.Plan(o, 20, nil)), "unaffordable")
  T.Eq(select(2, Purchases.Plan(o, nil, nil)), "money_unknown")
  T.Eq(plan.expectedRevenue, 1250)
  T.Eq(plan.expectedProfit, 350)
end)

T.Case("commodity: quote within plan, one click spends, ledger records the real cost", function()
  local s = setup()
  local p = s.app.purchases
  T.Ok(p:Begin(s.find(101), 5000))
  T.Ok(p:Prepare())
  T.Eq(s.ah.calls.StartCommoditiesPurchase, 1)
  T.Eq(s.ah.args.StartCommoditiesPurchase[2], 30)
  T.Eq(s.ah.spendCalls, 0, "a quote spends nothing")
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  T.Eq(p.current.state, "quoted")
  s.clock.advance(100)
  T.Eq(s.ah.spendCalls, 0, "no spending without a click")
  -- Quote validity: a fresh quote is needed after this long; refresh it.
  T.Ok(p:Confirm())
  T.Eq(s.ah.spendCalls, 1)
  T.Eq(s.ah.args.ConfirmCommoditiesPurchase[1], 101)
  T.Eq(s.ah.args.ConfirmCommoditiesPurchase[2], 30)
  s.wallet.money = s.wallet.money - 1100
  s.app:OnEvent("COMMODITY_PURCHASE_SUCCEEDED")
  T.Eq(p.current.state, "done")
  local entry = s.app.store.db.ledger[1]
  T.Eq(entry.cost, 1100)
  T.Eq(entry.quantity, 30)
  T.Eq(entry.status, "done")
  T.Eq(entry.remaining, 30)
  -- Bought units leave the opportunity list.
  s.app.opportunities:Consume(p.current.plan)
  s.app:EvaluateChunked()
  s.clock.advance(5)
  T.Eq(s.find(101), nil)
end)

T.Case("a higher quote is refused and cancelled; nothing can be confirmed", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 40, 1200)
  T.Eq(p.current.state, "rejected")
  T.Eq(p.current.reason, "price_up")
  T.Eq(s.ah.calls.CancelCommoditiesPurchase, 1)
  T.NotOk(p:Confirm())
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("expired quote or missing gold blocks the click", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  s.ah.quoteLeft = 0
  T.NotOk(p:Confirm())
  T.Eq(p.current.reason, "quote_expired")
  s.ah.quoteLeft = 30
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  s.wallet.money = 500
  T.NotOk(p:Confirm())
  T.Eq(p.current.reason, "unaffordable")
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("no answer after the click: uncertain, recorded, never retried", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  p:Confirm()
  s.clock.advance(60)
  T.Eq(p.current.state, "uncertain")
  T.Eq(s.ah.spendCalls, 1)
  T.Eq(s.app.store.db.ledger[1].status, "uncertain")
end)

T.Case("server refusal and AH closing stop the purchase", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  p:Confirm()
  s.app:OnEvent("COMMODITY_PURCHASE_FAILED")
  T.Eq(p.current.state, "failed")
  T.Eq(#s.app.store.db.ledger, 0)
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  s.app:OnEvent("AUCTION_HOUSE_CLOSED")
  T.Eq(p.current.state, "cancelled")
  T.Eq(s.ah.calls.CancelCommoditiesPurchase, 1)
end)

T.Case("individual auction: read-only search locates it, one click buys it", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200 } } })
  local o = s.find(201)
  T.Ok(o, "vendor opportunity on a non-commodity")
  T.Eq(o.commodity, false)
  local p = s.app.purchases
  p:Begin(o, 5000)
  T.Eq(p.current.plan.kind, "auction")
  T.Ok(p:Prepare())
  T.Eq(p.current.state, "locating")
  s.ah.items[201] = { { quantity = 1, buyout = 200, auctionID = 77 } }
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  T.Eq(p.current.state, "located")
  T.Eq(s.ah.spendCalls, 0)
  T.Ok(p:Confirm())
  T.Eq(s.ah.args.PlaceBid[1], 77)
  T.Eq(s.ah.args.PlaceBid[2], 200)
  s.app:OnEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 77)
  T.Eq(p.current.state, "done")
end)

T.Case("individual auction gone or dearer: rejected, nothing bought", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200 } } })
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  p:Prepare()
  s.ah.items[201] = { { quantity = 1, buyout = 250, auctionID = 78 } }
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  T.Eq(p.current.state, "rejected")
  T.Eq(p.current.reason, "lot_gone")
  T.Eq(s.ah.spendCalls, 0)
end)

local function buyLinen(s)
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  p:Confirm()
  s.wallet.money = s.wallet.money - 1100
  s.bags[101] = 30
  s.app:OnEvent("COMMODITY_PURCHASE_SUCCEEDED")
end

T.Case("vendor check: exact gold for the units sold verifies the vendor price", function()
  local s = setup({ bags = {} })
  local Capabilities = s.ns.Core.Capabilities
  T.NotOk(Capabilities.IsVerified("sellPrice"))
  buyLinen(s)
  local reports = {}
  s.app.bus:Subscribe("vendor.check", function(report) reports[#reports + 1] = report end)
  s.app:OnEvent("MERCHANT_SHOW")
  s.bags[101] = 0
  s.wallet.money = s.wallet.money + 1500
  s.app:OnEvent("MERCHANT_CLOSED")
  local report = reports[1]
  T.Eq(report.sold, 30)
  T.Eq(report.expected, 1500)
  T.Eq(report.gained, 1500)
  T.Ok(report.match)
  T.Eq(report.profit, 400)
  T.Ok(report.verifiedNow)
  T.Ok(Capabilities.IsVerified("sellPrice"))
  T.Eq(s.app.store.db.verifiedRuntime.sellPrice.sold, 30)
  local entry = s.app.store.db.ledger[1]
  T.Eq(entry.remaining, 0)
  T.Eq(entry.revenue, 1500)
end)

T.Case("vendor check: other income in the same visit does not verify anything", function()
  local s = setup({ bags = {} })
  buyLinen(s)
  local reports = {}
  s.app.bus:Subscribe("vendor.check", function(report) reports[#reports + 1] = report end)
  s.app:OnEvent("MERCHANT_SHOW")
  s.bags[101] = 10
  s.wallet.money = s.wallet.money + 1000 + 77
  s.app:OnEvent("MERCHANT_CLOSED")
  T.Eq(reports[1].sold, 20)
  T.NotOk(reports[1].match)
  T.NotOk(s.ns.Core.Capabilities.IsVerified("sellPrice"))
  T.Eq(s.app.store.db.ledger[1].remaining, 10)
end)

T.Case("with the vendor price verified the margin becomes VERIFIED", function()
  local s = setup()
  s.ns.Core.Capabilities.RecordRuntime("sellPrice", { t = 1 })
  s.app:EvaluateChunked()
  s.clock.advance(5)
  T.Eq(s.find(101).class, "vendor_confirmed")
end)
