-- Scanner replay: delayed, duplicated, missing and out-of-order events,
-- throttle, AH closing and reopening, cold item cache, foreign searches.
-- These prove the state machine against our fake, not the real server.
local ns = T.LoadAddon()
local ClientAdapter, AuctionHouse = ns.Compat.ClientAdapter, ns.Compat.AuctionHouse
local Scheduler, EventBus, Scanner = ns.Core.Scheduler, ns.Core.EventBus, ns.Services.Scanner

local function rows(n, extra)
  local list = {}
  for index = 1, n do
    local row = { itemID = 100 + index, count = (index % 5) + 1, buyout = 1000 * index, minBid = 10 }
    for key, value in pairs(extra or {}) do row[key] = value end
    list[index] = row
  end
  return list
end

local function setup(rowList, opts)
  local s = { clock = Fakes.Clock(), states = {}, snapshots = {}, invalidations = 0 }
  s.ah = Fakes.AuctionHouse(rowList)
  s.env = Fakes.Env(s.clock, s.ah)
  s.adapter = AuctionHouse.New(ClientAdapter.New(s.env))
  s.scheduler = Scheduler.New(s.clock.env())
  s.bus = EventBus.New()
  s.bus:Subscribe("scanner.state", function(state, reason) s.states[#s.states + 1] = state .. ":" .. tostring(reason) end)
  s.bus:Subscribe("scanner.snapshot", function(snapshot, listings) s.snapshots[#s.snapshots + 1] = { snapshot = snapshot, listings = listings } end)
  s.bus:Subscribe("quotes.invalidate", function() s.invalidations = s.invalidations + 1 end)
  s.scanner = Scanner.New({
    adapter = s.adapter, scheduler = s.scheduler, clock = s.clock.now, bus = s.bus,
    marketKey = function() return "m1|p18|3|R|Alliance" end, build = function() return "1.60.1" end,
  }, opts)
  function s.event(name, ...) s.adapter:OnEvent(name, ...) end
  function s.deliver(times)
    s.ah.delivered = true
    for _ = 1, times or 1 do s.event("REPLICATE_ITEM_LIST_UPDATE") end
  end
  return s
end

T.Case("scan refused with the AH closed; read-only and single task", function()
  local s = setup(rows(3))
  local ok, reason = s.scanner:Start()
  T.NotOk(ok)
  T.Eq(reason, "ah_closed")
  s.event("AUCTION_HOUSE_SHOW")
  T.Ok(s.scanner:Start())
  T.Eq(select(2, s.scanner:Start()), "busy")
  T.Eq(s.ah.replicateCalls, 1)
end)

T.Case("happy path with duplicate updates: each row once, partial until verified", function()
  local s = setup(rows(40))
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  T.Eq(s.scanner.state, "REQUESTED")
  s.clock.advance(1)
  s.deliver(3) -- duplicated notifications
  s.clock.advance(1)
  s.event("REPLICATE_ITEM_LIST_UPDATE") -- late duplicate before settle
  s.clock.advance(30)
  T.Eq(s.scanner.state, "PARTIAL")
  T.Eq(s.scanner.reason, "completeness_unverified")
  T.Eq(#s.snapshots, 1)
  local snap, listings = s.snapshots[1].snapshot, s.snapshots[1].listings
  T.Eq(#listings, 40)
  T.Eq(snap.counts.rows, 40)
  T.Eq(snap.counts.valid, 40)
  T.Eq(snap.coverage, "full_unverified")
  T.Eq(snap.indexBase, 0)
  T.Eq(listings[1].buyoutTotal, 1000)
  for _, listing in ipairs(listings) do
    for _, value in pairs(listing) do T.Ok(value ~= "SellerName" and value ~= "SellerName-Realm", "no seller names") end
  end
  T.Eq(s.ah.spendCalls, 0)
  -- Update after completion: nothing appended, no new snapshot.
  s.event("REPLICATE_ITEM_LIST_UPDATE")
  s.clock.advance(30)
  T.Eq(#s.snapshots, 1)
end)

T.Case("rows are read over several frames within the budget", function()
  local s = setup(rows(200), { budgetMs = 2 })
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(10)
  local frames = s.clock.frames
  T.Ok(frames >= 40, "200 rows at ~4 per 2 ms frame, got " .. frames)
  T.Eq(#s.snapshots[1].listings, 200)
end)

T.Case("no response: bounded retries with backoff, then failed", function()
  local s = setup(rows(3), { maxRetries = 2, timeout = 10 })
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.clock.advance(1000)
  T.Eq(s.scanner.state, "FAILED")
  T.Eq(s.scanner.reason, "no_response")
  T.Eq(s.ah.replicateCalls, 3)
end)

T.Case("throttle: waits, resumes on ready event, still one request at a time", function()
  local s = setup(rows(3))
  s.ah.ready = false
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  T.Eq(s.scanner.state, "THROTTLED")
  T.Eq(s.ah.replicateCalls, 0)
  s.ah.ready = true
  s.event("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
  T.Eq(s.scanner.state, "REQUESTED")
  T.Eq(s.ah.replicateCalls, 1)
  s.clock.advance(5) -- the backoff timer of the throttled attempt must not fire a second request
  T.Eq(s.ah.replicateCalls, 1)
end)

T.Case("AH closed while receiving: cancelled, timers dead, quotes invalidated", function()
  local s = setup(rows(5))
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.event("AUCTION_HOUSE_CLOSED")
  T.Eq(s.scanner.state, "CANCELLED")
  T.Eq(s.invalidations, 1)
  local before = #s.states
  s.clock.advance(1000)
  T.Eq(#s.states, before, "no late transitions")
  T.Eq(#s.snapshots, 0)
  T.Eq(s.ah.replicateCalls, 1, "no retry after close")
  -- Reopen and scan again cleanly.
  s.event("AUCTION_HOUSE_SHOW")
  T.Ok(s.scanner:Start())
  s.deliver()
  s.clock.advance(30)
  T.Eq(#s.snapshots, 1)
end)

T.Case("AH closed while reading: partial observation with the rows read", function()
  local s = setup(rows(200), { budgetMs = 2 })
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(2) -- settle elapsed, first frames read
  T.Eq(s.scanner.state, "NORMALIZING")
  s.event("AUCTION_HOUSE_CLOSED")
  T.Eq(s.scanner.state, "PARTIAL")
  T.Eq(s.scanner.reason, "ah_closed")
  local listings = s.snapshots[1].listings
  T.Ok(#listings > 0 and #listings < 200, "some rows: " .. #listings)
  T.Eq(s.snapshots[1].snapshot.coverage, "partial")
end)

T.Case("updates out of order or without a request are ignored", function()
  local s = setup(rows(3))
  s.ah.delivered = true
  s.event("REPLICATE_ITEM_LIST_UPDATE")
  T.Eq(s.scanner.state, "IDLE")
  s.clock.advance(100)
  T.Eq(#s.snapshots, 0)
end)

T.Case("cold item cache: one bounded re-read, then variant stays unknown", function()
  local list = rows(4)
  list[2].hasAllInfo = false
  list[3].hasAllInfo = false
  local s = setup(list, { infoWait = 3 })
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(2.5) -- settle elapsed; first pass done, re-read pending
  list[2].hasAllInfo = nil -- item data arrived for one row
  s.clock.advance(30)
  T.Eq(s.scanner.state, "PARTIAL")
  T.Eq(s.scanner.reason, "rows_incomplete")
  local listings = s.snapshots[1].listings
  T.Eq(#listings, 4)
  local unknown = 0
  for _, listing in ipairs(listings) do
    if ns.Data.Schema.IsVariantUnknown(listing.itemKey) then
      unknown = unknown + 1
      T.NotOk(listing.buyable, "incomplete rows are not buyable")
    end
  end
  T.Eq(unknown, 1)
  T.Eq(s.snapshots[1].snapshot.coverage, "partial")
end)

T.Case("1-based index fallback when index 0 is empty", function()
  local s = setup(rows(3))
  local api = s.ah.api
  local original = api.GetReplicateItemInfo
  api.GetReplicateItemInfo = function(index) return original(index - 1) end
  local originalLink = api.GetReplicateItemLink
  api.GetReplicateItemLink = function(index) return originalLink(index - 1) end
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(30)
  T.Eq(s.snapshots[1].snapshot.indexBase, 1)
  T.Eq(#s.snapshots[1].listings, 3)
end)

T.Case("passive observation of the user's commodity search, deduplicated", function()
  local s = setup({})
  s.ah.commodity[2589] = {
    { quantity = 20, unitPrice = 15, auctionID = 1 },
    { quantity = 5, unitPrice = 20, auctionID = 2, own = true },
  }
  s.event("AUCTION_HOUSE_SHOW")
  s.event("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  s.event("COMMODITY_SEARCH_RESULTS_UPDATED", 2589) -- duplicate notification
  T.Eq(#s.snapshots, 1)
  local snap, listings = s.snapshots[1].snapshot, s.snapshots[1].listings
  T.Eq(snap.mode, "observed_search")
  T.Eq(snap.coverage, "full_unverified")
  T.Eq(listings[1].unitPrice, 15)
  T.Eq(listings[1].buyoutTotal, 300)
  T.NotOk(listings[2].buyable, "own auction")
  T.Eq(s.ah.searchCalls, 0, "passive: no query sent")
  s.clock.advance(120)
  s.event("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  T.Eq(#s.snapshots, 2, "after the dedupe window it counts again")
end)

T.Case("multi-unit item search rows are not buyable until the price meaning is verified", function()
  local s = setup({})
  s.ah.items[7] = { { quantity = 1, buyout = 500, auctionID = 9 }, { quantity = 5, buyout = 900, auctionID = 10 } }
  s.event("AUCTION_HOUSE_SHOW")
  s.event("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })
  local listings = s.snapshots[1].listings
  T.Ok(listings[1].buyable)
  T.NotOk(listings[2].buyable)
end)

T.Case("targeted search: another search changing results suspends the task", function()
  local s = setup({})
  s.event("AUCTION_HOUSE_SHOW")
  local got
  T.Ok(s.scanner:Search(2589, 0, function(_, listings) got = listings end))
  T.Eq(s.ah.searchCalls, 1)
  s.event("COMMODITY_SEARCH_RESULTS_UPDATED", 9999)
  T.Eq(s.scanner.state, "FAILED")
  T.Eq(s.scanner.reason, "search_changed")
  T.Eq(got, nil)
end)

T.Case("targeted search: matching results reach the callback; timeout otherwise", function()
  local s = setup({})
  s.ah.commodity[2589] = { { quantity = 3, unitPrice = 15, auctionID = 1 } }
  s.event("AUCTION_HOUSE_SHOW")
  local got
  s.scanner:Search(2589, 0, function(_, listings) got = listings end)
  s.event("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
  T.Eq(#got, 1)
  T.Eq(s.scanner:Search(2589, 0, function() end), true)
  s.clock.advance(60)
  T.Eq(s.scanner.reason, "no_response")
  T.Eq(s.ah.spendCalls, 0)
end)

T.Case("user cancel invalidates timers and the generation", function()
  local s = setup(rows(3))
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.scanner:Cancel("user")
  T.Eq(s.scanner.state, "CANCELLED")
  s.clock.advance(100)
  T.Eq(#s.snapshots, 0)
end)

T.Case("hundreds of late updates while reading are counted, not appended", function()
  local traced = {}
  local s = setup(rows(200), { budgetMs = 2 })
  s.scanner.trace = function(kind, data) traced[#traced + 1] = kind end
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(2.1) -- reading started
  for _ = 1, 300 do s.event("REPLICATE_ITEM_LIST_UPDATE") end
  s.clock.advance(30)
  local snap = s.snapshots[1].snapshot
  T.Eq(#s.snapshots[1].listings, 200)
  T.Eq(snap.lateUpdates, 300)
  local ignored = 0
  for _, kind in ipairs(traced) do if kind == "replicate_update_ignored" then ignored = ignored + 1 end end
  T.Eq(ignored, 3, "traced at 1, 10 and 100 only")
end)

T.Case("item data arriving in a later round completes the rows", function()
  local list = rows(3)
  list[2].hasAllInfo = false
  local s = setup(list, { infoWait = 3, infoRounds = 4 })
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(6) -- first pass and first re-read: still missing
  list[2].hasAllInfo = nil
  s.clock.advance(30)
  T.Eq(s.scanner.reason, "completeness_unverified")
  T.Eq(s.snapshots[1].snapshot.coverage, "full_unverified")
  T.Ok(s.snapshots[1].snapshot.rounds >= 2)
end)

T.Case("stack samples and raw item strings are kept as evidence", function()
  local list = rows(10)
  list[4].suffix = 1179
  local s = setup(list)
  s.event("AUCTION_HOUSE_SHOW")
  s.scanner:Start()
  s.deliver()
  s.clock.advance(30)
  local snap = s.snapshots[1].snapshot
  T.Eq(#snap.samples, 8)
  T.Ok(snap.samples[1].count > 1 and snap.samples[1].buyout ~= nil)
  local withSuffix = false
  for _, link in ipairs(snap.links) do
    T.Ok(link:match("^item:[%-%d:]+$"), "item string only: " .. link)
    if link:find(":1179:", 1, true) then withSuffix = true end
  end
  T.Ok(withSuffix, "suffix links are preferred")
  T.Ok(#snap.links <= 6)
end)
