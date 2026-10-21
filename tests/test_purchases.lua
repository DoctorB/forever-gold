-- Assisted buying and the vendor check on a fake client. The fake proves our
-- state machine and safety rules, not the real server's behaviour.
local ITEMS = {
  [101] = { name = "Linen", sellPrice = 50 },
  [201] = { name = "Green Sword", sellPrice = 300, classID = 2 },
  [102] = { name = "Ore", sellPrice = 40 },
  [103] = { name = "Eye", sellPrice = 20 },
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
  local inbox = options.inbox or {}
  local app, ns, clock, ah = Fakes.App({ rows = rows, items = ITEMS, wallet = wallet, bags = bags, inbox = inbox })
  ah.commodityItems[101] = options.commodity101 ~= false and true or false
  ah.commodityItems[201] = false
  ah.commodityItems[102] = true
  ah.commodityItems[103] = true
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
  return { app = app, ns = ns, clock = clock, ah = ah, wallet = wallet, bags = bags, find = find, inbox = inbox }
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
  Capabilities.VERIFIED.sellPrice = false -- prove the runtime path
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
  s.ns.Core.Capabilities.VERIFIED.sellPrice = false
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
  s.ns.Core.Capabilities.VERIFIED.sellPrice = false
  s.app:EvaluateChunked()
  s.clock.advance(5)
  T.Eq(s.find(101).class, "prudent", "not verified yet")
  s.ns.Core.Capabilities.RecordRuntime("sellPrice", { t = 1 })
  s.app:EvaluateChunked()
  s.clock.advance(5)
  T.Eq(s.find(101).class, "vendor_confirmed")
end)

T.Case("individual auction: no answer to the search stops waiting", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200 } } })
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  p:Prepare()
  T.Eq(p.current.state, "locating")
  s.clock.advance(30)
  T.Eq(p.current.state, "rejected")
  T.Eq(p.current.reason, "no_answer")
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("vendor purchase accepts any variant of the item; the attempt is traced", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200,
    link = "|Hitem:201::::::::20:1486::1:1:12730:::::|h[Green Sword]|h" } } })
  local o = s.find(201)
  T.Eq(o.itemKey, "i:201:0:b12730")
  local p = s.app.purchases
  p:Begin(o, 5000)
  p:Prepare()
  -- The search result carries no bonus in its key (no link): same item, other key.
  s.ah.items[201] = { { quantity = 1, buyout = 190, auctionID = 91 } }
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  T.Eq(p.current.state, "located")
  T.Eq(p.current.auction.amount, 190)
  local found
  for _, e in ipairs(s.app.store.db.diagnostics.trace) do
    if e.k == "purchase_locate" then found = e end
  end
  T.Ok(found, "locate traced")
  T.Eq(found.rows, 1)
  T.Eq(found.matched, 1)
  T.Eq(found.planKey, "i:201:0:b12730")
end)

T.Case("an offer found gone leaves the list until fresh data arrives", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200 } } })
  local p = s.app.purchases
  local opportunity = s.find(201)
  s.ns.UI = s.ns.UI or {}
  p:Begin(opportunity, 5000)
  p:Prepare()
  s.ah.items[201] = { { quantity = 1, buyout = 999, auctionID = 92 } }
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  T.Eq(p.current.reason, "lot_gone")
  s.app.opportunities:MarkStale(201)
  s.app:EvaluateChunked()
  s.clock.advance(5)
  T.Eq(s.find(201), nil)
  T.Eq(s.app.opportunities.results.excluded.stale, 1)
end)

T.Case("portfolio: realized gain counts sold units; the rest is inventory", function()
  local s = setup()
  local Portfolio = s.ns.Services.Portfolio
  local ledger = {
    { kind = "purchase", status = "done", name = "Pyrite", itemID = 1, quantity = 8, cost = 640, sellPrice = 100,
      remaining = 0, sold = 8, revenue = 800, t = 1 },
    { kind = "purchase", status = "done", name = "Linen", itemID = 2, quantity = 30, cost = 1100, sellPrice = 50,
      remaining = 10, sold = 20, revenue = 1000, t = 2 },
    { kind = "purchase", status = "uncertain", name = "Axe", itemID = 3, quantity = 1, cost = 200, t = 3 },
  }
  local report = Portfolio.Report(ledger)
  local t = report.totals
  T.Eq(t.purchases, 2)
  T.Eq(t.spent, 1740)
  T.Eq(t.revenue, 1800)
  T.Eq(t.realized, 160 + (1000 - 733))
  T.Eq(t.pendingUnits, 10)
  T.Eq(t.pendingCost, 1100 - 733)
  T.Eq(t.pendingExpected, 500)
  T.Eq(t.uncertain, 1)
  T.Eq(report.entries[1].name, "Axe", "newest first")
end)

T.Case("portfolio table: cards and rows after a purchase and a merchant visit", function()
  local s = setup({ bags = {} })
  local Panel = s.ns.UI.Panels.portfolio
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 37, 1100)
  p:Confirm()
  s.wallet.money = s.wallet.money - 1100
  s.bags[101] = 30
  s.app:OnEvent("COMMODITY_PURCHASE_SUCCEEDED")
  local report = s.ns.Services.Portfolio.Report(s.app.store.db.ledger)
  local cards = Panel.Cards(report)
  T.Eq(cards[4].label, "Still to sell (30 items)")
  T.Eq(cards[4].value, "15s 0c")
  local row = Panel.Rows(report, function() return "20/10 14:00" end)[1]
  T.Eq(row.cells[2], "Linen")
  T.Eq(row.cells[4], "11s 0c")
  T.Eq(row.cells[7], "-", "no gain before selling")
  T.Eq(row.cells[9], s.ns.L.PORT_STATUS_bags)
  s.app:OnEvent("MERCHANT_SHOW")
  s.bags[101] = 0
  s.wallet.money = s.wallet.money + 1500
  s.app:OnEvent("MERCHANT_CLOSED")
  report = s.ns.Services.Portfolio.Report(s.app.store.db.ledger)
  cards = Panel.Cards(report)
  T.Eq(cards[1].value, "+4s 0c")
  T.Eq(cards[2].value, "11s 0c")
  T.Eq(cards[3].value, "15s 0c")
  row = Panel.Rows(report, function() return "" end)[1]
  T.Eq(row.cells[5], "30")
  T.Eq(row.cells[6], "15s 0c")
  T.Eq(row.cells[7], "+4s 0c")
  T.Eq(row.cells[8], "0")
  T.Eq(row.cells[9], s.ns.L.PORT_STATUS_sold)
end)

T.Case("history tables: scans newest first, prices with days and reference", function()
  local s = setup()
  local Panel = s.ns.UI.Panels.history
  local scans = Panel.ScanRows(s.app)
  T.Eq(#scans, 1)
  T.Eq(scans[1].cells[2], s.ns.L.MODE_replicate)
  T.Eq(scans[1].cells[4], "3")
  local prices = Panel.PriceRows(s.app)
  T.Eq(#prices, 1)
  T.Eq(prices[1].cells[1], "Linen")
  T.Eq(prices[1].cells[2], "-", "no reference with one day of data")
  T.Eq(prices[1].cells[3], "1")
  T.Ok(Panel.SummaryLine(s.app):find("1 items with prices", 1, true) ~= nil, Panel.SummaryLine(s.app))
end)

local BATCH_ROWS = {
  { itemID = 101, count = 20, buyout = 700 }, -- Linen: profit 300
  { itemID = 102, count = 10, buyout = 300 }, -- Ore: profit 100
  { itemID = 103, count = 30, buyout = 450 }, -- Eye: profit 150
}

local function quoteAndClick(s, unit, total)
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", unit, total)
  T.Ok(s.app.batch.ready, "ready after the quote")
  T.Ok(s.app.purchases:Confirm(), "click")
  s.wallet.money = s.wallet.money - total
  s.app:OnEvent("COMMODITY_PURCHASE_SUCCEEDED")
end

T.Case("batch queue: vendor offers only, best profit first", function()
  local s = setup({ rows = BATCH_ROWS })
  local queue = s.ns.Services.Batch.Queue(s.app.opportunities.results.list)
  T.Eq(#queue, 3)
  T.Eq(queue[1].itemID, 101)
  T.Eq(queue[2].itemID, 103)
  T.Eq(queue[3].itemID, 102)
end)

T.Case("buy all: prepares each purchase by itself, spends only on clicks", function()
  local s = setup({ rows = BATCH_ROWS })
  local batch = s.app.batch
  T.Ok(batch:Start(s.app.opportunities.results.list, 5000))
  T.Eq(s.ah.calls.StartCommoditiesPurchase, 1, "first quote requested automatically")
  T.Eq(s.ah.args.StartCommoditiesPurchase[1], 101)
  s.clock.advance(5)
  T.Eq(s.ah.spendCalls, 0, "nothing spent without a click")
  quoteAndClick(s, 35, 700)
  T.Eq(s.ah.calls.StartCommoditiesPurchase, 2, "next quote requested automatically")
  T.Eq(s.ah.args.StartCommoditiesPurchase[1], 103)
  quoteAndClick(s, 15, 450)
  T.Eq(s.ah.args.StartCommoditiesPurchase[1], 102)
  quoteAndClick(s, 30, 300)
  T.NotOk(batch.active)
  T.Eq(batch.stopReason, "done")
  T.Eq(batch.bought, 3)
  T.Eq(batch.spent, 1450)
  T.Eq(batch.expected, 1000 + 600 + 400)
  T.Eq(s.ah.spendCalls, 3, "exactly one spending call per click")
  T.Eq(#s.app.store.db.ledger, 3)
end)

T.Case("buy all: the total limit caps the run", function()
  local s = setup({ rows = BATCH_ROWS })
  local batch = s.app.batch
  batch:Start(s.app.opportunities.results.list, 1000)
  quoteAndClick(s, 35, 700) -- Linen 700, 300 left
  -- Eye: 30 x 15 = 450 does not fit: the plan shrinks to 20 units (300).
  T.Eq(s.ah.args.StartCommoditiesPurchase[1], 103)
  T.Eq(s.ah.args.StartCommoditiesPurchase[2], 20)
  quoteAndClick(s, 15, 300)
  T.NotOk(batch.active)
  T.Eq(batch.stopReason, "cap")
  T.Eq(batch.spent, 1000)
end)

T.Case("buy all: a dearer offer is skipped, an uncertain outcome stops everything", function()
  local s = setup({ rows = BATCH_ROWS })
  local batch = s.app.batch
  batch:Start(s.app.opportunities.results.list, 5000)
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 40, 800) -- Linen dearer than planned
  T.Eq(batch.skipped, 1)
  T.Eq(s.ah.args.StartCommoditiesPurchase[1], 103, "moved on to the next offer")
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 15, 450)
  s.app.purchases:Confirm()
  s.clock.advance(60) -- no answer from the server
  T.NotOk(batch.active)
  T.Eq(batch.stopReason, "uncertain")
  T.Eq(s.ah.calls.StartCommoditiesPurchase, 2, "no further quote after an uncertain outcome")
  T.Eq(s.ah.spendCalls, 1)
end)

T.Case("buy all: closing the AH stops the run", function()
  local s = setup({ rows = BATCH_ROWS })
  local batch = s.app.batch
  batch:Start(s.app.opportunities.results.list, 5000)
  s.app:OnEvent("AUCTION_HOUSE_CLOSED")
  T.NotOk(batch.active)
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("purchase waits for the AH throttle instead of failing", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  s.ah.ready = false
  T.Ok(p:Prepare())
  T.Eq(p.current.state, "waiting")
  T.Eq(s.ah.calls.StartCommoditiesPurchase, nil, "nothing sent while throttled")
  s.ah.ready = true
  s.app:OnEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  T.Eq(p.current.state, "quoting")
  T.Eq(s.ah.calls.StartCommoditiesPurchase, 1)
end)

T.Case("purchase gives up after waiting too long for the throttle", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  s.ah.ready = false
  p:Prepare()
  s.clock.advance(20)
  T.Eq(p.current.state, "rejected")
  T.Eq(p.current.reason, "throttled")
end)

T.Case("buy all: an immediate refusal skips once and never cancels the next quote", function()
  local s = setup({ rows = BATCH_ROWS })
  local api = s.ah.api
  local original = api.StartCommoditiesPurchase
  api.StartCommoditiesPurchase = function(itemID, ...)
    if itemID == 101 then error("refused") end
    return original(itemID, ...)
  end
  local batch = s.app.batch
  batch:Start(s.app.opportunities.results.list, 5000)
  T.Eq(batch.skipped, 1)
  T.Eq(s.app.purchases.current.plan.itemID, 103)
  T.Eq(s.app.purchases.current.state, "quoting")
  T.Eq(s.ah.calls.CancelCommoditiesPurchase, nil, "no quote cancelled by the batch")
  quoteAndClick(s, 15, 450)
  T.Eq(s.app.purchases.current.plan.itemID, 102, "then the next one")
end)

T.Case("buy all: a busy AH between purchases waits, it does not skip", function()
  local s = setup({ rows = BATCH_ROWS })
  local batch = s.app.batch
  batch:Start(s.app.opportunities.results.list, 5000)
  s.app:OnEvent("COMMODITY_PRICE_UPDATED", 35, 700)
  s.app.purchases:Confirm()
  s.ah.ready = false
  s.app:OnEvent("COMMODITY_PURCHASE_SUCCEEDED")
  T.Eq(s.app.purchases.current.state, "waiting")
  T.Eq(batch.skipped, 0)
  s.ah.ready = true
  s.clock.advance(2)
  T.Eq(s.app.purchases.current.state, "quoting")
  T.Eq(s.app.purchases.current.plan.itemID, 103)
end)

T.Case("buy all: offers found gone stay out of the queue", function()
  local s = setup({ rows = BATCH_ROWS })
  s.app.opportunities:MarkStale(101)
  s.app.batch:Start(s.app.opportunities.results.list, 5000)
  T.Eq(s.ah.args.StartCommoditiesPurchase[1], 103)
end)

T.Case("variant items are searched with their item level", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200,
    link = "|Hitem:201::::::::20:1486::1:1:12730:::::|h[Green Sword]|h" } } })
  s.app.client.env.C_Item.GetDetailedItemLevelInfo = function(link) return link:find("12730", 1, true) and 25 or nil end
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  p:Prepare()
  T.Eq(s.ah.lastSearch.itemID, 201)
  T.Eq(s.ah.lastSearch.itemLevel, 25)
end)

T.Case("variant auction not reached by the built key: browse finds the server key", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200,
    link = "|Hitem:201::::::::20:1486::1:1:12720:::::|h[Green Sword]|h" } } })
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  s.ah.items[201] = { { quantity = 1, buyout = 200, auctionID = 501, level = 22 } }
  s.ah.browse = {
    { itemKey = { itemID = 999, itemLevel = 5, itemSuffix = 0, battlePetSpeciesID = 0 }, totalQuantity = 1, minPrice = 10 },
    { itemKey = { itemID = 201, itemLevel = 22, itemSuffix = 0, battlePetSpeciesID = 0 }, totalQuantity = 1, minPrice = 1300 },
  }
  local function results(level)
    s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = level, itemSuffix = 0, battlePetSpeciesID = 0 })
  end
  p:Prepare()
  results(0) -- the built key (level 0) sees no row
  T.Eq(p.current.state, "locating")
  s.clock.advance(1)
  T.Eq(s.ah.browseCalls, 1, "browse by name")
  T.Eq(s.ah.lastBrowse.searchString, "Green Sword")
  s.app:OnEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  s.clock.advance(1)
  T.Eq(s.ah.lastSearch.itemLevel, 22, "searched with the server key")
  results(22)
  T.Eq(p.current.state, "located")
  T.Eq(p.current.auction.auctionID, 501)
  local browse
  for _, e in ipairs(s.app.store.db.diagnostics.trace) do if e.k == "purchase_browse" then browse = e end end
  T.Eq(browse.sameItem, 1)
  T.Eq(browse.keys, "22/0/0")
end)

T.Case("multi-unit auction: refused while the search price meaning is unverified", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200 } } })
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  p:Prepare()
  s.ah.items[201] = { { quantity = 2, buyout = 200, auctionID = 77 } }
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  T.Eq(p.current.state, "rejected", "a lower PlaceBid could become a bid, not a buyout")
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("grouped item-search rows are priced per unit and never bought", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200 } } })
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  p:Prepare()
  s.ah.items[201] = { { quantity = 2, buyout = 150, auctionID = 77 } }
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  T.Eq(p.current.state, "rejected", "what PlaceBid buys on a grouped row is unknown")
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("AH search test: variants and multi-unit lots probed read-only, results saved", function()
  local s = setup({ rows = {
    { itemID = 201, count = 1, buyout = 200, link = "|Hitem:201::::::::20:1486::1:1:12720:::::|h[Green Sword]|h" },
    { itemID = 202, count = 2, buyout = 100 },
  } })
  ITEMS[202] = ITEMS[202] or { name = "Pair of Boots", sellPrice = 10 }
  s.ah.commodityItems[202] = false
  s.app.items.cache[202] = nil
  -- server data: the sword exists only under level 22, the boots lot of 2 costs 100 in total
  s.ah.items[201] = { { quantity = 1, buyout = 200, auctionID = 1, level = 22 } }
  s.ah.items[202] = { { quantity = 2, buyout = 100, auctionID = 2 } }
  s.ah.browse = { { itemKey = { itemID = 201, itemLevel = 22, itemSuffix = 0, battlePetSpeciesID = 0 } } }
  local lines = {}
  s.app.bus:Subscribe("probe.progress", function(kind, data) lines[#lines + 1] = { kind, data } end)
  T.Ok(s.app.probe:Start())
  local function itemResults(itemID, level)
    s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = itemID, itemLevel = level, itemSuffix = 0, battlePetSpeciesID = 0 })
  end
  for _ = 1, 20 do
    s.clock.advance(1)
    local search = s.ah.lastSearch
    if search and not s.ah.answered then
      s.ah.answered = true
    end
    if s.app.scanner.task and s.app.scanner.task.mode == "search" then
      itemResults(s.app.scanner.task.itemID, s.ah.lastSearch.itemLevel)
    elseif s.app.scanner.task and s.app.scanner.task.mode == "browse" then
      s.app:OnEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end
    if not s.app.probe.running then break end
  end
  T.NotOk(s.app.probe.running, "finished")
  local report = s.app.store.db.diagnostics.probe
  T.Eq(report.variants, 1)
  T.Eq(report.lots, 1)
  T.Eq(report.votes.total, 1, "the boots row equals the replicate lot total")
  T.Eq(report.votes.unit, 0)
  local kinds = {}
  for _, entry in ipairs(report.results) do kinds[entry.kind] = entry end
  T.Eq(kinds.variant_direct.rows, 0)
  T.Eq(kinds.variant_browse.keys, "22/0/0")
  T.Eq(kinds.variant_key.rows, 1)
  T.Eq(s.ah.spendCalls, 0, "read-only")
  T.Eq(lines[#lines][1], "done")
end)

T.Case("variant items are searched with the Forever key: level and bonus ID + 1580", function()
  local s = setup({ rows = { { itemID = 201, count = 1, buyout = 200,
    link = "|Hitem:201::::::::20:1486::1:1:12742:::::|h[Green Sword]|h" } } })
  s.app.client.env.C_Item.GetDetailedItemLevelInfo = function() return 25 end
  local p = s.app.purchases
  p:Begin(s.find(201), 5000)
  s.ah.items[201] = { { quantity = 1, buyout = 200, auctionID = 9, level = 25 } }
  p:Prepare()
  T.Eq(s.ah.lastSearch.itemLevel, 25)
  T.Eq(s.ah.lastSearch.itemSuffix, 14322)
  s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 201, itemLevel = 25, itemSuffix = 14322, battlePetSpeciesID = 0 })
  T.Eq(p.current.state, "located", "found at the first try, no browse")
  T.Eq(s.ah.browseCalls, nil)
  T.Eq(s.ns.Compat.AuctionHouse.SuffixForBonus("12720.12800"), nil, "several bonus IDs: no guess")
end)

T.Case("AH search test: stackable non-commodity items are probed; lot-size mismatch recorded", function()
  local s = setup({ rows = { { itemID = 210, count = 1, buyout = 100 } } })
  ITEMS[210] = { name = "Stackable Thing", sellPrice = 80 }
  s.ah.commodityItems[210] = false
  s.app.items.cache[210] = nil
  local env = s.app.client.env
  local baseInfo = env.C_Item.GetItemInfo
  env.C_Item.GetItemInfo = function(itemID)
    if itemID == 210 then return "Stackable Thing", "link", 1, 1, 1, "T", "S", 5, "", 1, 80, 15, 0, 0 end
    return baseInfo(itemID)
  end
  s.ah.items[210] = { { quantity = 2, buyout = 100, auctionID = 3 } }
  T.Ok(s.app.probe:Start())
  for _ = 1, 10 do
    s.clock.advance(1)
    if s.app.scanner.task and s.app.scanner.task.mode == "search" then
      s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 210, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
    end
    if not s.app.probe.running then break end
  end
  local report = s.app.store.db.diagnostics.probe
  T.Eq(report.lots, 1)
  T.Eq(report.votes.unit, 1, "1x100 in the replicate, 2x100 in the search: price per unit")
  local lot
  for _, e in ipairs(report.results) do if e.kind == "lots" then lot = e end end
  T.Eq(lot.stackCount, 5)
  T.Eq(lot.sample, "2x100")
end)

T.Case("purchase events are traced while a purchase is in progress", function()
  local s = setup()
  local p = s.app.purchases
  p:Begin(s.find(101), 5000)
  p:Prepare()
  s.app:OnEvent("AUCTION_HOUSE_SHOW_ERROR", 7)
  local found
  for _, e in ipairs(s.app.store.db.diagnostics.trace) do
    if e.k == "purchase_event" and e.event == "AUCTION_HOUSE_SHOW_ERROR" then found = e end
  end
  T.Ok(found)
  T.Eq(found.a, "7")
  T.Eq(found.state, "quoting")
end)

T.Case("AH search test: two single auctions at one price grouped by the search", function()
  local s = setup({ rows = { { itemID = 211, count = 1, buyout = 150 }, { itemID = 211, count = 1, buyout = 150 } } })
  ITEMS[211] = { name = "Plain Ring", sellPrice = 200 }
  s.ah.commodityItems[211] = false
  s.ah.items[211] = { { quantity = 2, buyout = 300, auctionID = 4 } }
  T.Ok(s.app.probe:Start())
  for _ = 1, 10 do
    s.clock.advance(1)
    if s.app.scanner.task and s.app.scanner.task.mode == "search" then
      s.app:OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 211, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
    end
    if not s.app.probe.running then break end
  end
  local report = s.app.store.db.diagnostics.probe
  T.Eq(report.lots, 1)
  T.Eq(report.votes.total, 1, "2x300 for two singles at 150: price per lot")
  T.Eq(report.votes.unit, 0)
end)

T.Case("fee test: deposit measured at posting, fee from the sale invoice", function()
  ITEMS[2840] = { name = "Copper Bar", sellPrice = 50 }
  local s = setup({ bags = { [2840] = 20 }, money = 9676 })
  s.ah.depositPerUnit = 3 -- 2 h: 60, 8 h: 120, 24 h: 180 for 20 bars
  s.ns.Core.Capabilities.VERIFIED.deposit, s.ns.Core.Capabilities.VERIFIED.fee = false, false
  local test = s.app.feeTest
  T.Ok(test:Start())
  local state = test:State()
  T.Eq(state.stage, "armed")
  T.Eq(state.deposits[1], 60)
  T.Eq(state.deposits[2], 120)
  -- The player sells two bars to a merchant first: not a posting.
  s.bags[2840] = 18
  s.wallet.money = s.wallet.money + 100
  s.app:OnEvent("PLAYER_MONEY")
  T.Eq(state.stage, "armed")
  T.Eq(state.count, 18)
  -- Now posts the 18 bars for 8 h: 108 copper deposit.
  s.bags[2840] = 0
  s.wallet.money = s.wallet.money - 108
  s.app:OnEvent("AUCTION_HOUSE_AUCTION_CREATED", 4242)
  T.Eq(state.stage, "posted")
  T.Eq(state.posted.deposit, 108)
  T.Eq(state.posted.duration, 2)
  T.Eq(#state.posted.durations, 1)
  T.Ok(s.ns.Core.Capabilities.IsVerified("deposit"))
  T.Eq(s.ah.ownedQueries, 1)
  s.ah.owned = { { auctionID = 4242, itemKey = { itemID = 2840 }, quantity = 18, buyoutAmount = 110 } }
  s.app:OnEvent("OWNED_AUCTIONS_UPDATED")
  T.Eq(state.posted.buyout, 110)
  -- Sold: the invoice shows price 1980, deposit 108 back, AH cut 99.
  s.inbox[1] = { invoiceType = "seller", itemName = "Copper Bar", subject = "Auction successful: Copper Bar", money = 1989,
    bid = 1980, buyout = 1980, deposit = 108, consignment = 99 }
  s.app:OnEvent("MAIL_INBOX_UPDATE")
  T.Eq(state.stage, "sold")
  T.Eq(state.result.feeBp, 500)
  T.Eq(s.app.store:Settings().feeBp, 500)
  T.Ok(s.app.store:Settings().feeVerified)
  T.Ok(s.ns.Core.Capabilities.IsVerified("fee"))
  -- The same invoice seen again is not counted twice.
  s.app:OnEvent("MAIL_INBOX_UPDATE")
  T.Eq(#state.sales, 1)
  T.Eq(s.ah.spendCalls, 0, "nothing posted or bought by the add-on")
end)

T.Case("fee test: a deposit matching two quotes leaves the duration open", function()
  ITEMS[2840] = { name = "Copper Bar", sellPrice = 50 }
  local s = setup({ bags = { [2840] = 20 }, money = 9676 })
  s.ah.depositPerUnit, s.ah.minDeposit = 2, 100 -- 20 bars: 2 h 100, 8 h 100, 24 h 120 (as measured in game)
  s.ns.Core.Capabilities.VERIFIED.deposit = false
  T.Ok(s.app.feeTest:Start())
  local state = s.app.feeTest:State()
  s.bags[2840] = 0
  s.wallet.money = s.wallet.money - 100
  s.app:OnEvent("AUCTION_HOUSE_AUCTION_CREATED", 4242)
  T.Eq(state.stage, "posted")
  T.Eq(state.posted.duration, nil)
  T.Eq(table.concat(state.posted.durations, ","), "1,2")
  T.Ok(s.ns.Core.Capabilities.IsVerified("deposit"))
  T.Eq(s.app.store.db.verifiedRuntime.deposit.duration, nil)
  local line = s.ns.UI.Feedback.FeeTestLines("posted", state)[1]
  T.Ok(line:find("2/8 h", 1, true), line)
end)

T.Case("fee test refuses without the item or with the AH closed", function()
  local s = setup({ bags = {} })
  T.Eq(select(2, s.app.feeTest:Start(2840)), "no_item")
  s.app:OnEvent("AUCTION_HOUSE_CLOSED")
  T.Eq(select(2, s.app.feeTest:Start(2840)), "ah_closed")
end)
