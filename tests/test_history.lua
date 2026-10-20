local ns = T.LoadAddon()
local Schema, Store, History, Exchange, Migrations = ns.Data.Schema, ns.Data.Store, ns.Data.History, ns.Data.Exchange, ns.Data.Migrations
local DAY = ns.Economy.MarketValue.DAY

local A = Schema.MarketKey({ product = "p18", region = 3, realm = "R", faction = "Alliance" })
local H = Schema.MarketKey({ product = "p18", region = 3, realm = "R", faction = "Horde" })
local UNKNOWN = Schema.MarketKey({ product = "p18" })

local function listing(market, itemKey, quantity, total, index)
  return Schema.NewListing({ marketKey = market, itemKey = itemKey, quantity = quantity, buyoutTotal = total,
    divisible = false, source = "replicate", scanId = "s", index = index })
end

local function record(history, market, itemKey, price, t)
  history:Record({ id = "x" .. t, marketKey = market, coverage = "full_unverified", finished = t },
    { listing(market, itemKey, 1, price, 1) })
end

T.Case("unknown market fields form their own partition", function()
  T.Ok(A ~= H)
  T.Ok(UNKNOWN:find("|?|?|?", 1, true) ~= nil)
  T.Ok(UNKNOWN ~= A)
end)

T.Case("different variant or market never share history", function()
  local now = 100 * DAY
  local store = Store.New(nil, { now = now })
  local history = History.New(store, function() return now end)
  local plain, bear = Schema.ItemKey(10, 0), Schema.ItemKey(10, 1179)
  record(history, A, plain, 100, now)
  record(history, A, bear, 5000, now)
  record(history, H, plain, 900, now)
  T.Eq(history:Series(A, plain)[1].price, 100)
  T.Eq(history:Series(A, bear)[1].price, 5000)
  T.Eq(history:Series(H, plain)[1].price, 900)
  T.Eq(#history:Series(UNKNOWN, plain), 0)
end)

T.Case("suffix parsed from links; missing link means variant unknown", function()
  T.Eq(Schema.SuffixFromLink("|cff1eff00|Hitem:15210::::::1179:12345:60:::|h[Raider's Shortsword of the Bear]|h|r"), 1179)
  T.Eq(Schema.SuffixFromLink("|Hitem:2589::::::::60:::|h[Linen Cloth]|h"), 0)
  T.Eq(Schema.SuffixFromLink(nil), nil)
  T.Ok(Schema.IsVariantUnknown(Schema.ItemKey(10, nil, true)))
end)

T.Case("several scans in one day make one daily sample", function()
  local now = 100 * DAY
  local store = Store.New(nil, { now = now })
  local history = History.New(store, function() return now end)
  local key = Schema.ItemKey(10, 0)
  for index = 1, 10 do record(history, A, key, 100 + index, now + index) end
  local series = history:Series(A, key)
  T.Eq(#series, 1)
  T.Eq(series[1].price, 105)
end)

T.Case("retention: details 7 days, daily 90 days, ledger untouched", function()
  local now = 400 * DAY
  local store = Store.New(nil, { now = now })
  store.db.ledger[1] = { kind = "purchase" }
  local history = History.New(store, function() return now end)
  local key = Schema.ItemKey(10, 0)
  record(history, A, key, 100, now - 100 * DAY)
  record(history, A, key, 100, now - 10 * DAY)
  record(history, A, key, 100, now - 1 * DAY)
  local removed = history:Prune(now)
  T.Eq(removed.days, 1)
  T.Eq(removed.recent, 2)
  T.Eq(#history:Series(A, key), 2)
  T.Eq(#store.db.ledger, 1)
end)

T.Case("detailed observations are capped per item; over budget they are dropped first", function()
  local now = 100 * DAY
  local store = Store.New(nil, { now = now })
  local history = History.New(store, function() return now end)
  local key = Schema.ItemKey(10, 0)
  for index = 1, 30 do record(history, A, key, 100, now + index) end
  T.Eq(#history:Item(A, key).recent, History.MAX_RECENT_PER_ITEM)
  local budget = Store.RETENTION.budgetBytes
  Store.RETENTION.budgetBytes = 100
  local removed = history:Prune(now + 60)
  Store.RETENTION.budgetBytes = budget
  T.Ok(removed.overBudget)
  T.Eq(#history:Item(A, key).recent, 0)
  T.Eq(#history:Series(A, key), 1, "daily aggregate kept")
end)

T.Case("migration: fresh, idempotent and keeps unversioned content aside", function()
  local db, report = Migrations.Run(nil, ns.CopyTable)
  T.Eq(db.schema, Migrations.CURRENT)
  T.Eq(#report.applied, Migrations.CURRENT)
  local again, report2 = Migrations.Run(db, ns.CopyTable)
  T.Eq(again, db)
  T.Eq(#report2.applied, 0)
  local legacy = { prices = { a = 1 } }
  local migrated = Migrations.Run(legacy, ns.CopyTable)
  T.Eq(migrated.recovered.data.prices.a, 1)
  T.Eq(legacy.prices.a, 1, "original untouched")
end)

T.Case("migration failure or newer schema leaves the original and goes session-only", function()
  local newer = { schema = 99, markets = {} }
  local store = Store.New(newer)
  T.Ok(store.sessionOnly)
  T.Eq(store:Persisted(newer), newer)
  local saved = Migrations.steps[1]
  Migrations.steps[1] = function() error("boom") end
  local original = { stuff = true }
  local db, report = Migrations.Run(original, ns.CopyTable)
  Migrations.steps[1] = saved
  T.Eq(db, original)
  T.Ok(report.readOnly)
  T.Ok(report.error ~= nil)
end)

T.Case("store keeps settings and does not reset the DB on every login", function()
  local first = Store.New(nil, { now = 1 })
  first.db.settings.budget = 50000
  local second = Store.New(first.db, { now = 2 })
  T.Eq(second.db.settings.budget, 50000)
  T.Eq(second.db.meta.loads, 2)
  T.Eq(second.db.meta.previousLoad, 1)
end)

T.Case("export then import into an empty store round-trips", function()
  local now = 100 * DAY
  local store = Store.New(nil, { now = now })
  local history = History.New(store, function() return now end)
  record(history, A, Schema.ItemKey(10, 0), 123, now)
  local text = Exchange.Export(store, A)
  local other = Store.New(nil)
  local report = Exchange.Import(other, text, A)
  T.Ok(report.ok)
  T.Eq(report.added, 1)
  T.Eq(History.New(other, function() return now end):Series(A, Schema.ItemKey(10, 0))[1].price, 123)
  local again = Exchange.Import(other, text, A)
  T.Eq(again.skipped, 1, "existing days kept")
end)

T.Case("malformed or oversize import is refused without touching the DB", function()
  local store = Store.New(nil)
  local before = Store.EstimateBytes(store.db)
  local cases = {
    "garbage",
    Exchange.HEADER .. " " .. A .. "\ni:10:0 1 2",
    Exchange.HEADER .. " " .. A .. "\ni:10:0 1 0 5",
    Exchange.HEADER .. " " .. A .. "\nreturn os.exit()",
    Exchange.HEADER .. " " .. A .. "\n" .. string.rep("i:10:0 1 2 3\n", 30000),
    42,
  }
  for index, text in ipairs(cases) do
    local report = Exchange.Import(store, text, A)
    T.NotOk(report.ok, "case " .. index)
  end
  T.Eq(Exchange.Import(store, Exchange.HEADER .. " " .. H .. "\n", A).error, "other_market")
  T.Eq(Store.EstimateBytes(store.db), before)
end)

T.Case("selective reset never clears the ledger", function()
  local store = Store.New(nil)
  store:Market(A, true)
  store.db.ledger[1] = { kind = "sale" }
  T.Ok(store:Reset("history", A))
  T.Eq(store.db.markets[A], nil)
  T.Eq(#store.db.ledger, 1)
  T.NotOk(store:Reset("ledger"))
end)

T.Case("Forever links: variants come as bonus IDs and enter the item key", function()
  local link = "|cff1eff00|Hitem:15268::::::::20:1486::1:1:12730:1:28:5256:::::|h[Axe of the Bear]|h|r"
  local itemID, suffix, bonus = Schema.VariantFromLink(link)
  T.Eq(itemID, 15268)
  T.Eq(suffix, 0)
  T.Eq(bonus, "12730")
  T.Eq(Schema.ItemKey(itemID, suffix, false, bonus), "i:15268:0:b12730")
  local plain = { Schema.VariantFromLink("item:4257::::::::20:1486:::::::::") }
  T.Eq(plain[3], "")
  T.Eq(Schema.ItemKey(plain[1], plain[2], false, plain[3]), "i:4257:0")
  T.Eq(select(3, Schema.VariantFromLink("item:1::::::::60:0::0:3:300:200:100:0")), "100.200.300", "sorted")
  T.Eq(Schema.SuffixOf("i:15268:0:b12730"), 0)
  T.Eq(Schema.ItemIDOf("i:15268:0:b12730"), 15268)
  T.Ok(Schema.IsItemKey("i:15268:0:b12730.12731"))
  T.NotOk(Schema.IsItemKey("i:15268:?"))
end)

T.Case("bonus variants keep separate history and survive export/import", function()
  local now = 100 * DAY
  local store = Store.New(nil, { now = now })
  local history = History.New(store, function() return now end)
  record(history, A, "i:15268:0:b12730", 9000, now)
  record(history, A, "i:15268:0:b12731", 200, now)
  T.Eq(history:Series(A, "i:15268:0:b12730")[1].price, 9000)
  T.Eq(history:Series(A, "i:15268:0:b12731")[1].price, 200)
  local other = Store.New(nil)
  local report = Exchange.Import(other, Exchange.Export(store, A), A)
  T.Ok(report.ok, tostring(report.error))
  T.Eq(report.added, 2)
end)

T.Case("migration 2 raises the old 1-copper vendor threshold, keeps a custom one", function()
  local old = { schema = 1, settings = { minVendorProfit = 1 }, markets = {} }
  local db = Migrations.Run(old, ns.CopyTable)
  T.Eq(db.schema, 2)
  T.Eq(db.settings.minVendorProfit, 25)
  local custom = Migrations.Run({ schema = 1, settings = { minVendorProfit = 7 } }, ns.CopyTable)
  T.Eq(custom.settings.minVendorProfit, 7)
end)
