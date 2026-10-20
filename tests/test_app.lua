-- App wiring end to end on a fake client: diagnostics, scan -> history ->
-- opportunities, demo isolation, slash commands. Fakes only.
local ITEMS = { [101] = { name = "Linen", sellPrice = 50 }, [102] = { name = "Ore", sellPrice = 5 } }

local function replicateRows()
  return {
    { itemID = 101, count = 20, buyout = 700 }, -- vendor margin 300
    { itemID = 102, count = 10, buyout = 5000 },
    { itemID = 102, count = 1, buyout = 0, minBid = 100 }, -- bid only
  }
end

T.Case("load: diagnostics are non-destructive and complete", function()
  local app, ns, _, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  local report = app.diagnostics:Run()
  T.Eq(report.build.interface, 16001)
  T.Eq(report.build.projectID, 18)
  T.Eq(report.symbols["C_AuctionHouse.ReplicateItems"], "present")
  T.Eq(report.symbols["C_TradeSkillUI.GetRecipeInfo"], "unsupported")
  T.Eq(ah.spendCalls, 0)
  T.Eq(ah.replicateCalls, 0, "diagnostics never scans")
  local lines = ns.Services.Diagnostics.Summary(report, ns.L)
  T.Ok(lines[1]:find("70450", 1, true) ~= nil)
  T.Ok(app.store.db.diagnostics.report == report)
end)

T.Case("scan feeds history and a vendor opportunity with denominators", function()
  local app, _, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  T.Ok(app.scanner:Start())
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(30)
  local results = app.opportunities.results
  T.Ok(results ~= nil)
  T.Eq(results.counts.itemKeys, 2)
  T.Eq(results.counts.listings, 3)
  T.Eq(results.counts.units, 31)
  T.Eq(results.counts.candidates, 2)
  T.Eq(#results.list, 1)
  local o = results.list[1]
  T.Eq(o.strategy, "vendor")
  T.Eq(o.profit, 300)
  T.Eq(o.class, "prudent", "buyout meaning unverified: not 'confirmed'")
  T.Eq(o.allocation, "no_budget")
  T.Eq(results.excluded.insufficient_history, 2)
  local market = app.store:Market(app:MarketKey())
  T.Eq(market.itemCount, 2)
  T.Eq(ah.spendCalls, 0)
end)

T.Case("budget allocation respects reserve and per-item cap", function()
  local app, ns = Fakes.App({ rows = replicateRows(), items = ITEMS })
  local list = {
    { itemKey = "a", capital = 900, cost = 900, category = 1 },
    { itemKey = "b", capital = 1500, cost = 1500, category = 1 },
    { itemKey = "c", capital = 600, cost = 600, category = 2 },
  }
  ns.Services.Opportunities.Allocate(list, { budget = 10000, reserveBp = 2000, maxItemBp = 1000, maxCategoryBp = 2500 })
  T.Eq(list[1].allocation, "allocated")
  T.Eq(list[2].allocation, "item_cap")
  T.Eq(list[3].allocation, "allocated")
  T.Ok(app ~= nil)
end)

T.Case("demo mode is labelled and isolated from real history", function()
  local app, ns = Fakes.App({ rows = replicateRows(), items = ITEMS })
  local results = app:Demo()
  T.Ok(results.demo)
  T.Eq(results.marketKey, ns.Data.Demo.MARKET)
  T.Ok(#results.list >= 2, "vendor and resale examples")
  local strategies = {}
  for _, o in ipairs(results.list) do strategies[o.strategy] = true end
  T.Ok(strategies.vendor and strategies.resale)
  T.Eq(next(app.store.db.markets), nil, "real store untouched")
end)

T.Case("transactions: prepare never spends; changes invalidate", function()
  local app, ns, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  local opportunity = {
    itemKey = "i:2589:0", strategy = "resale",
    lots = { { quantity = 20, cost = 300, listing = { auctionID = 1, unitPrice = 15, divisible = true, quantity = 20 } } },
  }
  local prepared = app.transactions:Prepare(opportunity)
  T.Eq(prepared.total, 300)
  local fresh = { ns.Data.Schema.NewListing({ marketKey = "m", itemKey = "i:2589:0", quantity = 20, unitPrice = 15,
    divisible = true, auctionID = 1 }) }
  T.Eq(app.transactions:Revalidate(prepared, fresh), "valid")
  fresh[1].unitPrice = 16
  local status, reasons = app.transactions:Revalidate(prepared, fresh)
  T.Eq(status, "changed")
  T.Eq(reasons[1], "price_changed")
  clock.advance(120)
  T.Eq(app.transactions:Revalidate(prepared, fresh), "expired")
  app:OnEvent("AUCTION_HOUSE_CLOSED")
  T.Eq(prepared.status, "invalidated")
  T.Eq(ah.spendCalls, 0)
end)

T.Case("replicate lots without auction id revalidate by quantity and total", function()
  local app, ns = Fakes.App({})
  local Schema = ns.Data.Schema
  local lot = Schema.NewListing({ marketKey = "m", itemKey = "i:1:0", quantity = 5, buyoutTotal = 500, index = 1 })
  local prepared = app.transactions:Prepare({ itemKey = "i:1:0", lots = { { quantity = 5, cost = 500, listing = lot } } })
  local same = Schema.NewListing({ marketKey = "m", itemKey = "i:1:0", quantity = 5, buyoutTotal = 500, auctionID = 77 })
  T.Eq(app.transactions:Revalidate(prepared, { same }), "valid")
  local other = Schema.NewListing({ marketKey = "m", itemKey = "i:1:0", quantity = 5, buyoutTotal = 600, auctionID = 78 })
  T.Eq(app.transactions:Revalidate(prepared, { other }), "changed")
end)

T.Case("slash commands: scan refused when closed, diagnostics prints a summary", function()
  local app, ns = Fakes.App({ rows = replicateRows(), items = ITEMS })
  ns.UI.Commands.Handle("scan")
  T.Ok(ns.printed[#ns.printed]:find(ns.L.REASON_ah_closed, 1, true) ~= nil)
  ns.UI.Commands.Handle("diagnostics")
  T.Ok(#ns.printed >= 5)
  ns.UI.Commands.Handle("help")
  T.Ok(ns.printed[#ns.printed]:find("/fg demo", 1, true) ~= nil)
  T.Ok(app.loaded)
end)

T.Case("invalid events are not registered", function()
  local app, ns = Fakes.App({ invalidEvents = { REPLICATE_ITEM_LIST_UPDATE = true } })
  local frame = Fakes.Frame("Frame")
  local registered, rejected = app.client:RegisterEvents(frame, ns.Compat.ClientAdapter.EVENTS)
  T.Eq(#rejected, 1)
  T.Eq(rejected[1], "REPLICATE_ITEM_LIST_UPDATE")
  T.Eq(#registered, #ns.Compat.ClientAdapter.EVENTS - 1)
  T.NotOk(frame.events.REPLICATE_ITEM_LIST_UPDATE)
end)

T.Case("session-only mode hands the original table back", function()
  local saved = { schema = 1, settings = { sessionOnly = true }, markets = {} }
  local app = Fakes.App({ saved = saved })
  T.Ok(app.store.sessionOnly)
  T.Eq(app.store:Persisted(saved), saved)
end)

T.Case("large snapshot: history and evaluation spread over many frames", function()
  local rows = {}
  for index = 1, 600 do rows[index] = { itemID = 1000 + index, count = 2, buyout = 100 + index } end
  local app, _, clock, ah = Fakes.App({ rows = rows })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(2.5) -- settle elapsed, reading started
  T.Eq(app.opportunities.results, nil, "nothing evaluated inside one frame")
  local framesBefore = clock.frames
  clock.advance(60)
  T.Ok(clock.frames - framesBefore > 100, "frames used: " .. (clock.frames - framesBefore))
  T.Eq(app.opportunities.results.counts.itemKeys, 600)
  T.Eq(app.store:Market(app:MarketKey()).itemCount, 600)
end)

T.Case("item info arrives later: opportunities re-evaluate once", function()
  local pending = {}
  local app, _, clock, ah = Fakes.App({ rows = { { itemID = 101, count = 20, buyout = 700 } }, items = pending })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(30)
  T.Eq(#app.opportunities.results.list, 0)
  T.Eq(app.opportunities.results.counts.infoPending, 1)
  pending[101] = ITEMS[101]
  app:OnEvent("GET_ITEM_INFO_RECEIVED", 101, true)
  clock.advance(2)
  T.Eq(#app.opportunities.results.list, 1)
end)

T.Case("snapshot evidence and counts are saved with the market", function()
  local rowsList = {}
  for index = 1, 12 do rowsList[index] = { itemID = 200 + index, count = 3, buyout = 300 } end
  local app, _, clock, ah = Fakes.App({ rows = rowsList })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(60)
  local saved = app.store:Market(app:MarketKey()).snapshots[1]
  T.Eq(saved.counts.rows, 12)
  T.Eq(saved.counts.valid, 12)
  T.Eq(saved.indexBase, 0)
  T.Eq(saved.reason, "completeness_unverified")
  T.Eq(#saved.samples, 8)
  T.Ok(#saved.links > 0)
end)
