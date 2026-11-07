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
  T.Eq(o.class, "vendor_confirmed", "buyout and vendor price verified in game")
  T.Eq(o.pending, nil)
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

-- Profession window fakes: shapes are invented for the test, not taken
-- from the Forever client (that is what the in-game probe is for).
local function legacyProfession(calls)
  local list = {
    { "Smelting", "header" },
    { "Smelt Copper", "optimal", 3, link = "|Hitem:2840|h[Copper Bar]|h", made = { 1, 1 },
      reagents = { { "Copper Ore", 1, 3, "|Hitem:2770|h[Copper Ore]|h" } } },
    { "Smelt Bronze", "medium", 0, link = "|Hitem:2841|h[Bronze Bar]|h", made = { 2, 2 },
      reagents = { { "Copper Bar", 1, 0 }, { "Tin Bar", 1, 0 } } },
  }
  local function track(name, fn)
    return function(...)
      calls[name] = (calls[name] or 0) + 1
      return fn(...)
    end
  end
  return {
    GetTradeSkillLine = track("GetTradeSkillLine", function() return "Mining", 75, 150 end),
    GetNumTradeSkills = track("GetNumTradeSkills", function() return #list end),
    GetTradeSkillInfo = function(i) return list[i][1], list[i][2], list[i][3] end,
    GetTradeSkillItemLink = function(i) return list[i].link end,
    GetTradeSkillNumMade = function(i) return list[i].made[1], list[i].made[2] end,
    GetTradeSkillNumReagents = function(i) return #list[i].reagents end,
    GetTradeSkillReagentInfo = function(i, j)
      local r = list[i].reagents[j]
      return r[1], "texture", r[2], r[3]
    end,
    GetTradeSkillReagentItemLink = function(i, j) return list[i].reagents[j][4] end,
  }
end

T.Case("profession probe: classic list read when the window opens, read-only", function()
  local calls = {}
  local app, ns, clock = Fakes.App({ globals = legacyProfession(calls) })
  app:OnEvent("TRADE_SKILL_SHOW")
  app:OnEvent("TRADE_SKILL_LIST_UPDATE")
  app:OnEvent("TRADE_SKILL_LIST_UPDATE")
  clock.advance(2)
  T.Eq(calls.GetNumTradeSkills, 1, "one observation per burst of list events")
  local report = app.store.db.diagnostics.professions.Mining
  T.Ok(report, "saved under the profession name")
  T.Eq(report.legacy.line.rank, 75)
  T.Eq(report.legacy.count, 3)
  T.Eq(report.legacy.headers, 1)
  T.Eq(#report.legacy.recipes, 2)
  local copper = report.legacy.recipes[1]
  T.Eq(copper.name, "Smelt Copper")
  T.Eq(copper.madeMin, 1)
  T.Eq(copper.reagents[1].count, 1)
  T.Eq(copper.reagents[1].have, 3)
  T.Ok(copper.reagents[1].link:find("2770", 1, true) ~= nil)
  T.Eq(report.symbols.GetNumTradeSkills, true)
  T.Eq(report.symbols["C_TradeSkillUI.GetAllRecipeIDs"], false)
  T.Eq(report.modern.recipeIDs, nil)
  ns.UI.Commands.Handle("professions")
  local found
  for _, line in ipairs(ns.printed) do if line:find("Mining", 1, true) then found = line end end
  T.Ok(found and found:find("75/150", 1, true), "summary printed")
end)

T.Case("profession probe: modern recipe IDs keep the raw field names", function()
  local trade = {
    GetAllRecipeIDs = function() return { 2657, 2659 } end,
    GetRecipeInfo = function(id) return { recipeID = id, name = "Smelt " .. id, learned = true, craftable = true } end,
    GetRecipeSchematic = function(id)
      return { outputItemID = 2840, quantityMin = 1, quantityMax = 1,
        reagentSlotSchematics = { { quantityRequired = 1, reagents = { { itemID = 2770 } } } },
        callback = function() end }
    end,
    GetBaseProfessionInfo = function() return { professionName = "Mining", skillLevel = 75, maxSkillLevel = 150 } end,
  }
  local app = Fakes.App({ globals = { C_TradeSkillUI = trade } })
  local report = app:ObserveProfession()
  T.Eq(report.name, "Mining")
  T.Eq(report.modern.idSource, "GetAllRecipeIDs")
  T.Eq(#report.modern.recipeIDs, 2)
  local schematic = report.modern.recipes[1].schematic
  T.Eq(schematic.outputItemID, 2840)
  T.Eq(schematic.reagentSlotSchematics[1].reagents[1].itemID, 2770)
  T.Eq(schematic.callback, "function", "functions kept by type name only")
  T.Eq(report.modern.recipes[2].info.name, "Smelt 2659")
end)

T.Case("profession probe: a client error is recorded, not raised", function()
  local app = Fakes.App({ globals = {
    GetNumTradeSkills = function() return 1 end,
    GetTradeSkillInfo = function() error("no window") end,
    C_TradeSkillUI = {
      GetBaseProfessionInfo = function() return { professionName = "Cooking", skillLevel = 5, maxSkillLevel = 75 } end,
      GetAllRecipeIDs = function() error("not ready") end,
    },
  } })
  local report = app:ObserveProfession()
  T.Eq(report.name, "Cooking")
  T.Ok(tostring(report.modern.GetAllRecipeIDs):find("^error") ~= nil)
  T.Eq(#report.legacy.recipes, 0)
  T.Eq(#app.store.db.recipes.Cooking.list, 0)
end)

T.Case("profession probe: nothing is saved with no window open", function()
  -- Seen in game (build 70862): with the window closed the client answers
  -- with an empty profession name and the previous window's recipes.
  local app = Fakes.App({ globals = { C_TradeSkillUI = {
    GetBaseProfessionInfo = function() return { professionName = "", skillLevel = 0, maxSkillLevel = 0 } end,
    GetAllRecipeIDs = function() return { 1, 2, 3 } end,
  } } })
  local report, reason = app:ObserveProfession()
  T.Eq(report, nil)
  T.Eq(reason, "no_window")
  T.Eq(app.store.db.diagnostics.professions, nil)
  T.Eq(app.store.db.recipes, nil)
end)

T.Case("recipe compact form from the schematic seen in game", function()
  local ns = T.LoadAddon()
  local P = ns.Compat.Professions
  -- Field names as recorded on build 70862 (First Aid Kit, API-AUDIT row 24).
  local info = { recipeID = 1230117, name = "First Aid Kit", learned = true, relativeDifficulty = 3 }
  local schematic = { recipeID = 1230117, outputItemID = 279968, quantityMin = 1, quantityMax = 1,
    reagentSlotSchematics = {
      { quantityRequired = 3, required = true, reagentType = 1, reagents = { { itemID = 1251 } } },
      { quantityRequired = 1, required = true, reagentType = 1, reagents = { { itemID = 159 } } },
      { quantityRequired = 1, required = false, reagentType = 0, reagents = { { itemID = 9999 } } },
    } }
  local recipe = P.Compact(info, schematic, "First Aid")
  T.Eq(recipe.id, 1230117)
  T.Eq(recipe.learned, true)
  T.Eq(recipe.outputs[1].itemID, 279968)
  T.Eq(recipe.outputs[1].quantity, 1)
  T.Eq(#recipe.reagents, 2, "optional reagents left out")
  T.Eq(recipe.reagents[1].itemID, 1251)
  T.Eq(recipe.reagents[1].quantity, 3)
  T.Eq(P.Compact(info, { outputItemID = 0, quantityMin = 1 }), nil, "no output")
  T.Eq(P.Compact(info, { outputItemID = 5, quantityMin = 1, reagentSlotSchematics = {
    { quantityRequired = 1, reagents = {} } } }), nil, "unreadable reagent")
end)

-- Crafting on a fake market. Prices chosen so every exit is exercised:
--   Ore 102: commodity, 10 units at 30 each.   Bar 301: three auctions from 200, merchant 10.
--   Linen 101: not on the AH, merchant 50.     Eye 103: merchant 20.
local CRAFT_ITEMS = {
  [101] = { name = "Linen", sellPrice = 50 }, [102] = { name = "Ore", sellPrice = 5 },
  [103] = { name = "Eye", sellPrice = 20 }, [301] = { name = "Bar", sellPrice = 10 },
}
local CRAFT_RECIPES = {
  { id = 1, name = "Smelt Bar", learned = true, reagents = { { 102, 2 } }, output = { 301, 1 } },
  { id = 2, name = "Weave Linen", learned = false, reagents = { { 102, 1 } }, output = { 101, 2 } },
  { id = 3, name = "Eye Craft", learned = false, reagents = { { 102, 1 } }, output = { 103, 1 } },
  { id = 4, name = "Rare Bar", learned = false, reagents = { { 999, 1 } }, output = { 301, 1 } },
}

local function craftingApp(bags, extra, saved)
  local trade = {
    GetBaseProfessionInfo = function() return { professionName = "Mining", skillLevel = 23, maxSkillLevel = 75 } end,
    GetAllRecipeIDs = function() return { 1, 2, 3, 4 } end,
    GetRecipeInfo = function(id)
      local r = CRAFT_RECIPES[id]
      return { recipeID = id, name = r.name, learned = r.learned, relativeDifficulty = 0, maxTrivialLevel = r.trivial }
    end,
    GetRecipeSchematic = function(id)
      local r = CRAFT_RECIPES[id]
      local slots = {}
      for index, reagent in ipairs(r.reagents) do
        slots[index] = { quantityRequired = reagent[2], required = true, reagents = { { itemID = reagent[1] } } }
      end
      return { recipeID = id, outputItemID = r.output[1], quantityMin = r.output[2], quantityMax = r.output[2],
        reagentSlotSchematics = slots }
    end,
  }
  local rows = { { itemID = 102, count = 10, buyout = 300 }, { itemID = 301, count = 1, buyout = 200 },
    { itemID = 301, count = 1, buyout = 210 }, { itemID = 301, count = 1, buyout = 220 } }
  local globals = { C_TradeSkillUI = trade }
  for key, value in pairs(extra or {}) do globals[key] = value end
  local app, ns, clock, ah = Fakes.App({ rows = rows, items = CRAFT_ITEMS, globals = globals, bags = bags, saved = saved })
  ah.commodityItems[102] = true
  ah.commodityItems[301] = false
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(30)
  return app, ns, clock
end

T.Case("crafting: known recipes and learnable ones priced at real depth", function()
  local app, ns, clock = craftingApp()
  T.Eq(app.opportunities.results.crafting, nil, "no recipes before a window was opened")
  app:ObserveProfession()
  T.Eq(app.opportunities.results.crafting, nil, "spread over frames, not computed at once")
  clock.advance(1)
  local crafting = app.opportunities.results.crafting
  T.Ok(crafting, "evaluated when the recipes arrive")
  T.Eq(crafting.counts.recipes, 4)
  -- Smelt Bar: 2 ore = 60; bar on the AH now: 200 - 5% buffer = 190, minus 5% fee (10) = 180.
  T.Eq(#crafting.learned, 1)
  local bar = crafting.learned[1]
  T.Eq(bar.cost, 60)
  T.Eq(bar.exit, "ah_now")
  -- Deposit: merchant price 10 -> 3 for 8 h, raised to the 100 minimum;
  -- half counted as lost: 180 - 50.
  T.Eq(bar.revenue, 130)
  T.Eq(bar.profit, 70)
  T.Eq(bar.exits[1].deposit, 100)
  T.Eq(bar.class, "speculative")
  -- Weave Linen: 1 ore = 30 -> 2 linen to a merchant = 100.
  T.Eq(#crafting.learnable, 1)
  T.Eq(crafting.learnable[1].recipeID, 2)
  T.Eq(crafting.learnable[1].exit, "vendor")
  T.Eq(crafting.learnable[1].profit, 70)
  T.Eq(crafting.learnable[1].class, "prudent")
  T.Eq(crafting.excluded.no_profit, 1, "Eye Craft: 30 for 20")
  T.Eq(crafting.excluded.reagent_not_on_ah, 1)
  local lines = ns.UI.Commands.CraftingLines(app, 5)
  local text = table.concat(lines, "\n")
  T.Ok(text:find("Bar", 1, true) and text:find("Linen", 1, true), "both recipes reported")
end)

T.Case("crafting: recipes survive a reload and a bound result has no AH exit", function()
  local app = craftingApp()
  app:ObserveProfession()
  T.Eq(#app.store.db.recipes.Mining.list, 4)
  T.Eq(app.store.db.recipes.Mining.skill, 23)
  local reloaded, ns2 = Fakes.App({ saved = app.store.db, items = CRAFT_ITEMS })
  T.Eq(ns2.Data.Recipes.status, "observed")
  T.Eq(#ns2.Data.Recipes.List(), 4)
  local Crafting = ns2.Strategies.Crafting
  local best = Crafting.Exits({ levels = {}, sellPrice = 10, bound = true }, 1, { feeBp = 500, bufferBp = 500 })
  T.Eq(best.exit, "vendor")
  T.Eq(reloaded.loaded, true)
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
  clock.advance(5) -- after RESOLVE_QUIET (3 s) without new item data
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

T.Case("buyout meaning: stacks vote by comparing with single auctions", function()
  local _, ns = Fakes.App({})
  local Schema = ns.Data.Schema
  local function l(itemID, quantity, buyout)
    return Schema.NewListing({ marketKey = "m", itemKey = Schema.ItemKey(itemID, 0), quantity = quantity,
      buyoutTotal = buyout, source = "replicate" })
  end
  local totals = { l(1, 1, 100), l(1, 1, 110), l(1, 5, 520), l(1, 10, 990), l(2, 1, 50), l(2, 20, 1000), l(3, 4, 400) }
  local votes = ns.Services.Diagnostics.BuyoutVotes(totals)
  T.Eq(votes.items, 2)
  T.Eq(votes.total, 3)
  T.Eq(votes.unit, 0)
  local units = { l(1, 1, 100), l(1, 5, 105), l(1, 3, 98) }
  T.Eq(ns.Services.Diagnostics.BuyoutVotes(units).unit, 2)
end)

T.Case("scanner memory is seeded with the bounds measured in game", function()
  local app, ns = Fakes.App({})
  T.Eq(app.scanner.memory.lowerBound, ns.Services.Scanner.MEASURED.lowerBound)
  T.Eq(app.scanner.memory.upperBound, ns.Services.Scanner.MEASURED.upperBound)
  T.Eq(app.store.db.scanner, app.scanner.memory)
end)

T.Case("without the verified buyout meaning a vendor margin is only prudent", function()
  local app, ns, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  local verified = ns.Core.Capabilities.VERIFIED
  verified.replicateBuyoutIsTotal = false
  local ok, err = pcall(function()
    app:OnEvent("AUCTION_HOUSE_SHOW")
    app.scanner:Start()
    ah.delivered = true
    app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
    clock.advance(30)
    T.Eq(app.opportunities.results.list[1].class, "prudent")
  end)
  verified.replicateBuyoutIsTotal = true
  if not ok then error(err, 0) end
end)

T.Case("vendor variants merge into one row; small margins are hidden and counted", function()
  local rows = {
    { itemID = 300, count = 1, buyout = 260, suffix = 0, link = "|Hitem:300::::::::20:1486::1:1:11:::::|h[Axe]|h" },
    { itemID = 300, count = 1, buyout = 260, link = "|Hitem:300::::::::20:1486::1:1:12:::::|h[Axe]|h" },
    { itemID = 300, count = 1, buyout = 260, link = "|Hitem:300::::::::20:1486::1:1:13:::::|h[Axe]|h" },
    { itemID = 301, count = 1, buyout = 298 }, -- 2 copper margin: hidden
  }
  local items = { [300] = { name = "Axe", sellPrice = 300 }, [301] = { name = "Agate", sellPrice = 300 } }
  local app, _, clock, ah = Fakes.App({ rows = rows, items = items })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(60)
  local results = app.opportunities.results
  T.Eq(#results.list, 1)
  local o = results.list[1]
  T.Eq(o.itemID, 300)
  T.Eq(o.variants, 3)
  T.Eq(o.quantity, 3)
  T.Eq(o.profit, 120)
  T.Eq(#o.lots, 3)
  T.Eq(results.excluded.below_threshold, 1)
end)

T.Case("opportunities survive /reload while the replicate cools down", function()
  local app, _, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(60)
  T.Eq(#app.opportunities.results.list, 1)
  local saved = app.store.db
  T.Ok(saved.lastView and #saved.lastView.listings >= 1)
  -- /reload: a new App reads the same SavedVariables.
  local again = Fakes.App({ saved = saved, items = ITEMS, clock = clock })
  clock.advance(5)
  local results = again.opportunities.results
  T.Ok(results and #results.list == 1, "restored without scanning")
  T.Eq(results.list[1].profit, 300)
  T.Ok(results.snapshot.restored)
  T.Eq(again.scanner:Cooldown().remaining > 0, true, "cooldown remembered")
end)

T.Case("the saved view keeps the opportunity's lots and the cheapest auctions only", function()
  -- 200 single Linen auctions: 20 below the vendor price, 180 above it.
  local rows = {}
  for index = 1, 200 do rows[index] = { itemID = 101, count = 1, buyout = index <= 20 and 30 or 60 + index } end
  local app, _, clock, ah = Fakes.App({ rows = rows, items = ITEMS })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  T.Ok(app.scanner:Start())
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(60)
  T.Eq(#app.opportunities.results.list, 1)
  local saved = app.store.db.lastView.listings
  T.Eq(#saved, app.VIEW_CHEAPEST, "200 auctions trimmed to the cheapest")
  local cheap = 0
  for _, listing in ipairs(saved) do
    if listing.buyoutTotal == 30 then cheap = cheap + 1 end
  end
  T.Eq(cheap, 20, "every auction in the opportunity is kept")
  local again = Fakes.App({ saved = app.store.db, items = ITEMS, clock = clock })
  clock.advance(5)
  T.Eq(again.opportunities.results.list[1].profit, app.opportunities.results.list[1].profit, "same profit after /reload")
end)

T.Case("a scan records how long each pipeline phase took", function()
  local app, _, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  T.Ok(app.scanner:Start())
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(30)
  local seen = {}
  for _, timing in ipairs(app.store.db.diagnostics.timings or {}) do
    seen[timing.phase] = timing
    T.Ok(type(timing.worstMs) == "number" and timing.worstMs >= 0, timing.phase)
    T.Ok(timing.busyMs >= timing.worstMs, timing.phase)
  end
  for _, phase in ipairs({ "replicate_read", "history_begin", "group", "history", "history_finish",
    "evaluate_begin", "evaluate", "evaluate_finish" }) do
    T.Ok(seen[phase] ~= nil, "missing " .. phase)
  end
  T.Eq(seen.replicate_read.rows, 3)
  T.Ok(seen.replicate_read.frames >= 1)
  T.Eq(seen.group.rows, 3, "every raw listing goes through the chunked group phase")
  T.Ok(seen.history.slowestKey ~= nil and seen.history.slowestRows >= 1, "slowest history step named")
  T.Ok(seen.evaluate.slowestKey ~= nil, "slowest evaluate step named")
  T.Ok(app.store.db.markets[app:MarketKey()].snapshots[1].buyoutVotes ~= nil, "buyout evidence still recorded")
end)

T.Case("crafting: summary kept for the audit, a newer run cancels the older one", function()
  local app, _, clock = craftingApp()
  app:ObserveProfession()
  T.Ok(app:EvaluateCrafting(), "restart while the first run is pending")
  clock.advance(1)
  local saved = app.store.db.diagnostics.crafting
  T.Ok(saved, "summary saved")
  T.Eq(saved.totals.learned, 1)
  T.Eq(saved.learned[1].profit, 70)
  T.Eq(saved.learnable[1].recipeID, 2)
  T.Eq(saved.excluded.reagent_not_on_ah, 1)
  local crafting = 0
  for _, timing in ipairs(app.store.db.diagnostics.timings) do
    if timing.phase == "crafting" then crafting = crafting + 1 end
  end
  T.Eq(crafting, 1, "the cancelled run finished nothing")
end)

T.Case("profession window: list updates are throttled and unchanged recipes are not re-priced", function()
  local app, _, clock = craftingApp()
  local observed = 0
  local observe = app.professions.Observe
  app.professions.Observe = function(...)
    observed = observed + 1
    return observe(...)
  end
  app:OnEvent("TRADE_SKILL_SHOW")
  clock.advance(2)
  T.Eq(observed, 1)
  local runs = 0
  for _, timing in ipairs(app.store.db.diagnostics.timings) do if timing.phase == "crafting_begin" then runs = runs + 1 end end
  T.Eq(runs, 1, "priced once when the recipes arrive")
  for _ = 1, 10 do
    app:OnEvent("TRADE_SKILL_LIST_UPDATE")
    clock.advance(2)
  end
  T.Eq(observed, 1, "list updates within a minute are ignored")
  clock.advance(60)
  app:OnEvent("TRADE_SKILL_LIST_UPDATE")
  clock.advance(2)
  T.Eq(observed, 2, "observed again after a minute")
  app:OnEvent("TRADE_SKILL_SHOW")
  clock.advance(2)
  T.Eq(observed, 3, "opening a window always observes")
  runs = 0
  for _, timing in ipairs(app.store.db.diagnostics.timings) do if timing.phase == "crafting_begin" then runs = runs + 1 end end
  T.Eq(runs, 1, "same recipes: not priced again")
end)

T.Case("crafting: the current AH price needs at least 3 listings of the result", function()
  local ns = T.LoadAddon()
  local Crafting = ns.Strategies.Crafting
  local settings = { feeBp = 500, bufferBp = 500 }
  local function lots(n)
    local levels = {}
    for index = 1, n do levels[index] = { quantity = 1, buyoutTotal = 1000000, divisible = false, buyable = true } end
    return levels
  end
  -- One overpriced weapon: no AH exit, and no merchant price either.
  T.Eq(Crafting.Exits({ levels = lots(1), sellPrice = 0 }, 1, settings), nil)
  local market = function(itemID)
    if itemID == 1 then return { levels = { { quantity = 5, unitPrice = 10, divisible = true, buyable = true } } } end
    return { levels = lots(2), sellPrice = 0 }
  end
  local row, reason = Crafting.EvaluateRecipe({ id = 9, outputs = { { itemID = 2, quantity = 1 } },
    reagents = { { itemID = 1, quantity = 1 } } }, market, settings, {})
  T.Eq(row, nil)
  T.Eq(reason, "thin_market")
  local best = Crafting.Exits({ levels = lots(3), sellPrice = 0 }, 1, settings)
  T.Eq(best.exit, "ah_now")
end)

T.Case("crafting: a recipe learned in game is priced without reopening the window", function()
  local app, _, clock = craftingApp()
  app:ObserveProfession()
  clock.advance(1)
  T.Eq(#app.opportunities.results.crafting.learnable, 1)
  app:OnEvent("NEW_RECIPE_LEARNED", 2)
  clock.advance(1)
  local crafting = app.opportunities.results.crafting
  T.Eq(#crafting.learned, 2, "Weave Linen moved to the known recipes")
  T.Eq(#crafting.learnable, 0)
  T.Eq(app.store.db.recipes.Mining.list[2].learned, true, "saved")
  T.NotOk(app:OnRecipeLearned(424242), "unknown recipe: nothing to do")
end)

T.Case("crafting tab: rows, tooltip and summary", function()
  local app, ns, clock = craftingApp()
  local Panel = ns.UI.Panels.professions
  T.Ok(Panel.Summary(app):find("Open each profession window", 1, true), "asks for the windows first")
  app:ObserveProfession()
  clock.advance(1)
  local summary = Panel.Summary(app)
  T.Ok(summary:find("Mining 23/75", 1, true), "skill shown")
  T.Ok(summary:find("4 recipes, 3 priced", 1, true), summary)
  local crafting = app.opportunities.results.crafting
  local rows = Panel.Rows(app, crafting.learned)
  T.Eq(#rows, 1)
  T.Eq(rows[1].cells[2], "Bar")
  T.Eq(rows[1].cells[3], "1x", "the AH takes only one bar")
  T.Eq(rows[1].cells[5], "AH (now)")
  T.Eq(rows[1].cells[8], "3")
  local tip = table.concat(rows[1].tip, "\n")
  T.Ok(tip:find("2 x Ore", 1, true), tip)
  T.Ok(tip:find("3 listings", 1, true), tip)
  T.Ok(tip:find("would not take more", 1, true), tip)
  local learnable = Panel.Rows(app, crafting.learnable)
  T.Eq(learnable[1].cells[2], "2 x Linen")
  T.Eq(learnable[1].cells[3], "10x", "ten ore on the AH")
  T.Eq(learnable[1].cells[5], "Merchant")
  T.Eq(learnable[1].cells[7], "+7s 0c")
end)

-- Merchant fakes: classic positional API, as the shapes are not verified yet.
local function classicMerchant(items)
  return {
    GetMerchantNumItems = function() return #items end,
    GetMerchantItemInfo = function(i)
      local m = items[i]
      return m.name, "texture", m.price, m.stack or 1, m.available or -1, true, true, m.extended or false
    end,
    GetMerchantItemID = function(i) return items[i].itemID end,
  }
end

T.Case("merchant: unlimited gold offers priced per unit, read-only", function()
  local ns = T.LoadAddon()
  local client = ns.Compat.ClientAdapter.New(classicMerchant({
    { itemID = 2320, name = "Coarse Thread", price = 10 },
    { itemID = 2880, name = "Weak Flux", price = 95, stack = 5 },
    { itemID = 3371, name = "Empty Vial", price = 4, available = 3 },
    { itemID = 9999, name = "Token item", price = 0, extended = true },
  }))
  local report = ns.Compat.Merchant.New(client):Read()
  T.Eq(report.rows, 4)
  T.Eq(report.prices[2320], 10)
  T.Eq(report.prices[2880], 19, "95 for 5 -> 19 each")
  T.Eq(report.prices[3371], nil, "limited supply left out")
  T.Eq(report.skipped.limited, 1)
  T.Eq(report.skipped.extended_cost, 1)
  T.Eq(report.symbols.GetMerchantItemInfo, true)
  T.Eq(#report.samples, 3)
  T.Eq(ns.Compat.Merchant.New(ns.Compat.ClientAdapter.New({})):Read(), nil, "no merchant window")
end)

T.Case("merchant: modern C_MerchantFrame table read first", function()
  local ns = T.LoadAddon()
  local client = ns.Compat.ClientAdapter.New({
    GetMerchantNumItems = function() return 1 end,
    GetMerchantItemLink = function() return "|cffffffff|Hitem:2678::::::::8:1491:::::|h[Mild Spices]|h|r" end,
    C_MerchantFrame = { GetItemInfo = function()
      return { name = "Mild Spices", price = 10, stackCount = 1, numAvailable = -1, isPurchasable = true, hasExtendedCost = false }
    end },
  })
  local report = ns.Compat.Merchant.New(client):Read()
  T.Eq(report.prices[2678], 10, "item ID from the link")
  T.Eq(report.samples[1].raw.stackCount, 1, "raw shape kept")
end)

T.Case("crafting: a merchant reagent prices recipes and is used only when cheaper", function()
  local app, ns, clock = craftingApp()
  -- Recipe 4 needs item 999, sold only by merchants.
  app:ObserveProfession()
  clock.advance(1)
  T.Eq(app.opportunities.results.crafting.excluded.reagent_not_on_ah, 1)
  local merchant = classicMerchant({
    { itemID = 999, name = "Flux", price = 50 },
    { itemID = 102, name = "Ore", price = 100 }, -- dearer than the AH (30)
  })
  for key, value in pairs(merchant) do app.client.env[key] = value end
  app:OnEvent("MERCHANT_SHOW")
  clock.advance(2)
  T.Eq(app:MerchantPrice(999), 50)
  T.Eq(app.store.db.diagnostics.merchant.priced, 2)
  local crafting = app.opportunities.results.crafting
  T.Eq(crafting.excluded.reagent_not_on_ah, nil, "re-priced after the merchant visit")
  -- Rare Bar: flux 50 from the merchant -> bar on the AH 180 net: +130.
  local rare
  for _, row in ipairs(crafting.learnable) do if row.recipeID == 4 then rare = row end end
  T.Ok(rare, "Rare Bar now priced")
  T.Eq(rare.cost, 50)
  T.Eq(rare.reagents[1].merchant, true)
  T.Eq(rare.profit, 80, "180 - 50 expected deposit loss - 50 flux")
  T.Eq(crafting.learned[1].cost, 60, "ore still bought on the AH at 30")
  T.Eq(crafting.learned[1].reagents[1].merchant, false)
  T.Eq(crafting.learned[1].listings, 3, "the merchant is not AH competition")
  local tip = table.concat(ns.UI.Panels.professions.Rows(app, { rare })[1].tip, "\n")
  T.Ok(tip:find("(merchant)", 1, true), tip)
  -- Same visit again: nothing new, no re-pricing.
  T.Eq(app:ObserveMerchant(), 0)
end)

T.Case("status line describes the last full scan, not the restored or searched view", function()
  local app, ns, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(30)
  local Main = ns.UI.Main
  local before = Main.StatusLine(app, app.opportunities.results)
  T.Ok(before:find("3 auctions read · 2 items", 1, true), before)
  -- After /reload only the opportunity's auctions come back (1 of 3 here).
  local reloaded, ns2 = Fakes.App({ saved = app.store.db, items = ITEMS, clock = clock })
  clock.advance(5)
  T.Eq(reloaded.opportunities.results.counts.listings, 1, "the restored view is smaller than the scan")
  local after = ns2.UI.Main.StatusLine(reloaded, reloaded.opportunities.results)
  T.Ok(after:find("Last scan 0 min ago · 3 auctions read · 2 items", 1, true), after)
end)

-- Auto-scan (Services/AutoScan). The fake client accepts the call without
-- a click; whether Forever does is what the first real use will show.
local function autoApp()
  local app, ns, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  return app, ns, clock, ah
end

local function answer(app, ah, clock)
  ah.delivered = true
  app:OnEvent("REPLICATE_ITEM_LIST_UPDATE")
  clock.advance(30)
end

T.Case("auto-scan: off by default, nothing requested", function()
  local app, _, clock, ah = autoApp()
  app:OnEvent("AUCTION_HOUSE_SHOW")
  clock.advance(60)
  T.Eq(ah.replicateCalls, 0)
  T.Eq(app.autoScan:Status(), "off")
end)

T.Case("auto-scan: requests when the AH opens, then again when the cooldown ends", function()
  local app, ns, clock, ah = autoApp()
  app.autoScan:SetEnabled(true)
  app:OnEvent("AUCTION_HOUSE_SHOW")
  T.Eq(ah.replicateCalls, 1, "no cooldown known yet: at once")
  answer(app, ah, clock)
  T.Eq(app.store.db.autoScan.answered, 1)
  local kind, seconds = app.autoScan:Status()
  T.Eq(kind, "waiting")
  T.Ok(seconds > 800, "the measured cooldown is respected: " .. tostring(seconds))
  T.Ok(ns.UI.Main.StatusLine(app, app.opportunities.results):find("auto-scan in", 1, true), "shown in the status line")
  clock.advance(seconds - 10)
  T.Eq(ah.replicateCalls, 1, "not before the cooldown ends")
  clock.advance(20)
  T.Eq(ah.replicateCalls, 2, "requested by itself")
  T.Eq(ah.spendCalls, 0)
end)

T.Case("auto-scan: three silent requests in a row pause it until the AH reopens", function()
  local app, _, clock, ah = autoApp()
  app.autoScan:SetEnabled(true)
  app:OnEvent("AUCTION_HOUSE_SHOW")
  for _ = 1, 3 do clock.advance(app.scanner.opts.timeout + app.scanner.opts.silentPause + 10) end
  T.Eq(ah.replicateCalls, 3)
  T.Eq(app.autoScan:Status(), "silent")
  clock.advance(3600)
  T.Eq(ah.replicateCalls, 3, "no fourth request")
  app:OnEvent("AUCTION_HOUSE_CLOSED")
  app:OnEvent("AUCTION_HOUSE_SHOW")
  T.Eq(ah.replicateCalls, 4, "reopening the AH tries again")
end)

T.Case("auto-scan: a blocked call switches it off and is remembered", function()
  local app, ns, clock, ah = autoApp()
  app.autoScan:SetEnabled(true)
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app:OnEvent("ADDON_ACTION_BLOCKED", "ForeverGold", "C_AuctionHouse.ReplicateItems()")
  T.Eq(app.autoScan:Status(), "blocked")
  T.Eq(app.store:Settings().autoScan, false)
  T.Eq(app.store.db.autoScan.blocked.event, "ADDON_ACTION_BLOCKED")
  T.Ok(ns.UI.Main.StatusLine(app, app.opportunities.results):find("blocked", 1, true))
  clock.advance(3600)
  T.Eq(ah.replicateCalls, 1)
  -- Another add-on's block, or a late one, is not ours.
  local app2, _, clock2 = autoApp()
  app2.autoScan:SetEnabled(true)
  app2:OnEvent("AUCTION_HOUSE_SHOW")
  T.NotOk(app2.autoScan:OnBlocked("ADDON_ACTION_BLOCKED", "OtherAddon", "x"))
  clock2.advance(10)
  T.NotOk(app2.autoScan:OnBlocked("ADDON_ACTION_FORBIDDEN", "ForeverGold", "x"), "too late to be this request")
  T.Eq(app2.autoScan:Status(), "scanning")
end)

T.Case("auto-scan: never while a purchase run uses the AH or with the AH closed", function()
  local app, _, clock, ah = autoApp()
  app.store:Settings().autoScan = true
  app.batch.active = true
  app:OnEvent("AUCTION_HOUSE_SHOW")
  clock.advance(30)
  T.Eq(ah.replicateCalls, 0, "batch running")
  app.batch.active = false
  clock.advance(6)
  T.Eq(ah.replicateCalls, 1, "once the batch is over")
  answer(app, ah, clock)
  app:OnEvent("AUCTION_HOUSE_CLOSED")
  clock.advance(7200)
  T.Eq(ah.replicateCalls, 1, "AH closed: nothing")
end)

T.Case("deposit check: quotes for items in the bags compared with the formula, read-only", function()
  local quotes = { [2840] = { 100, 100, 120 }, [2589] = { 100, 100, 100 } }
  local bags = { [0] = { { itemID = 2840, stackCount = 20 }, { itemID = 2589, stackCount = 5 },
    { itemID = 6948, stackCount = 1, isBound = true } } }
  local items = { [2840] = { name = "Copper Bar", sellPrice = 10 }, [2589] = { name = "Linen Cloth", sellPrice = 3 },
    [6948] = { name = "Hearthstone", sellPrice = 1 } }
  local app, ns, clock, ah = Fakes.App({ rows = replicateRows(), items = items, globals = {
    C_Container = {
      GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
      GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
    },
    ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end },
  } })
  ah.commodityItems[2840] = true
  ah.commodityItems[2589] = false
  ah.api.CalculateCommodityDeposit = function(itemID, duration, quantity) return quotes[itemID][duration] end
  ah.api.CalculateItemDeposit = function(location, duration) return quotes[bags[location.bag][location.slot].itemID][duration] end
  app:OnEvent("AUCTION_HOUSE_SHOW")
  clock.advance(3)
  local memory = app.store.db.depositChecks
  T.Eq(#memory.samples, 2, "the bound Hearthstone is skipped")
  T.Eq(memory.items[2840], "match_rate", "20 bars: 100 / 100 / 120 as measured in game (120 tests the 24 h rate)")
  T.Eq(memory.samples[1].quantity, 20)
  T.Eq(memory.items[2589], "match", "one cloth: the 100 minimum for every duration")
  local status = app.depositCheck:Status()
  T.Eq(status.matched, 2)
  T.NotOk(status.verified, "five matching items are needed")
  T.Eq(ah.spendCalls, 0)
  -- Known items are not asked again.
  app:OnEvent("AUCTION_HOUSE_CLOSED")
  app:OnEvent("AUCTION_HOUSE_SHOW")
  clock.advance(3)
  T.Eq(#memory.samples, 2)
  local _ = ns
end)

T.Case("deposit check: a quote that differs from the formula is a mismatch", function()
  local bags = { [0] = { { itemID = 2840, stackCount = 20 } } }
  local app, _, clock, ah = Fakes.App({ rows = replicateRows(), items = { [2840] = { name = "Copper Bar", sellPrice = 10 } },
    globals = { C_Container = {
      GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
      GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
    } } })
  ah.commodityItems[2840] = true
  ah.api.CalculateCommodityDeposit = function(_, duration) return ({ 100, 150, 120 })[duration] end
  app:OnEvent("AUCTION_HOUSE_SHOW")
  clock.advance(3)
  T.Eq(app.store.db.depositChecks.items[2840], "mismatch")
  T.Eq(app.depositCheck:Status().mismatched, 1)
end)

T.Case("crafting: reagents in the bags lower the gold to spend, not the gain", function()
  local app, ns, clock = craftingApp({ [102] = 4 }) -- four ore in the bags
  app:ObserveProfession()
  clock.advance(1)
  local crafting = app.opportunities.results.crafting
  local bar = crafting.learned[1].run -- Smelt Bar: 2 ore (60), one craft
  T.Eq(bar.crafts, 1)
  T.Eq(bar.spend, 0, "both ore come from the bags")
  T.Eq(bar.ownedValue, 60)
  T.Eq(bar.owned[102], 2)
  T.Eq(bar.profit, 70, "the gain still counts the ore at its price")
  local linen = crafting.learnable[1].run -- Weave Linen: 1 ore each, ten crafts
  T.Eq(linen.crafts, 10)
  T.Eq(linen.cost, 300)
  T.Eq(linen.spend, 180, "six ore to buy")
  T.Eq(linen.ownedValue, 120)
  local rows = ns.UI.Panels.professions.Rows(app, crafting.learnable)
  T.Eq(rows[1].cells[4], "1s 80c", "To spend")
  local tip = table.concat(rows[1].tip, "\n")
  T.Ok(tip:find("(4 in your bags)", 1, true), tip)
  T.Ok(tip:find("gold to spend now 1s 80c", 1, true), tip)
end)

T.Case("tooltips: crafting gain for an item you can make, merchant price when known", function()
  local app, ns, clock = craftingApp()
  app:ObserveProfession()
  clock.advance(1)
  app.store.db.merchant = { prices = { [999] = { unit = 50, at = clock.now() } } }
  local Tips = ns.UI.Tooltips
  local bar = table.concat(Tips.Lines(app, "|cffffffff|Hitem:301::::::::|h[Bar]|h|r"), "\n")
  T.Ok(bar:find("craft: +70c for 1 (your recipe Smelt Bar)", 1, true), bar)
  local linen = table.concat(Tips.Lines(app, "|cffffffff|Hitem:101::::::::|h[Linen]|h|r"), "\n")
  T.Ok(linen:find("if you learn Weave Linen", 1, true), linen)
  local flux = table.concat(Tips.Lines(app, "|cffffffff|Hitem:999::::::::|h[Flux]|h|r"), "\n")
  T.Ok(flux:find("sold by a merchant for 50c", 1, true), flux)
  T.Eq(#Tips.Lines(app, "|cffffffff|Hitem:555::::::::|h[Nothing]|h|r"), 0)
end)

T.Case("crafting is re-priced once the bags are quiet", function()
  local app, _, clock = craftingApp()
  app:ObserveProfession()
  clock.advance(1)
  local function runs()
    local n = 0
    for _, timing in ipairs(app.store.db.diagnostics.timings) do if timing.phase == "crafting_begin" then n = n + 1 end end
    return n
  end
  local before = runs()
  for _ = 1, 5 do
    app:OnEvent("BAG_UPDATE_DELAYED")
    clock.advance(3)
  end
  T.Eq(runs(), before, "still changing: not yet")
  clock.advance(30)
  T.Eq(runs(), before + 1, "one re-pricing after the bags settled")
end)

T.Case("auto-scan: a scan that finds offers says so in chat with a sound", function()
  local sounds = {}
  local app, ns, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS,
    globals = { PlaySound = function(kit) sounds[#sounds + 1] = kit end } })
  ns.printed = {}
  app.autoScan:SetEnabled(true)
  app:OnEvent("AUCTION_HOUSE_SHOW")
  answer(app, ah, clock)
  local found
  for _, line in ipairs(ns.printed) do if line:find("automatic scan: 1 offers", 1, true) then found = line end end
  T.Ok(found, table.concat(ns.printed, "\n"))
  T.Eq(#sounds, 1)
  T.Eq(sounds[1], 8959)
  -- A scan from the button gets the usual summary, no alert.
  app.store:Settings().autoScan = false
  T.NotOk(app:AlertAutoScan(app.opportunities.results))
end)

T.Case("item data arriving in bursts starts one evaluation after a quiet moment", function()
  local app, _, clock, ah = Fakes.App({ rows = replicateRows(), items = ITEMS })
  app:OnEvent("AUCTION_HOUSE_SHOW")
  app.scanner:Start()
  answer(app, ah, clock)
  local function passes()
    local n = 0
    for _, timing in ipairs(app.store.db.diagnostics.timings) do if timing.phase == "evaluate_begin" then n = n + 1 end end
    return n
  end
  local before = passes()
  for _ = 1, 6 do
    app.bus:Publish("items.resolved", 101)
    clock.advance(1)
  end
  T.Eq(passes(), before, "still arriving")
  clock.advance(10)
  T.Eq(passes(), before + 1, "one pass for the whole burst")
end)

T.Case("deposit check: eight matches at the minimum do not verify the rates", function()
  -- Seen in game 2026-11-07 13:43: eight cheap items, all quoted 100.
  local bags, items = { [0] = {} }, {}
  for index = 1, 8 do
    bags[0][index] = { itemID = 3000 + index, stackCount = 1 }
    items[3000 + index] = { name = "Cheap " .. index, sellPrice = 5 }
  end
  local app, _, clock, ah = Fakes.App({ rows = replicateRows(), items = items, globals = { C_Container = {
    GetContainerNumSlots = function(bag) return bags[bag] and #bags[bag] or 0 end,
    GetContainerItemInfo = function(bag, slot) return bags[bag] and bags[bag][slot] end,
  }, ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end } } })
  ah.api.CalculateItemDeposit = function() return 100 end
  app:OnEvent("AUCTION_HOUSE_SHOW")
  clock.advance(3)
  local status = app.depositCheck:Status()
  T.Eq(status.matched, 8)
  T.Eq(status.aboveMinimum, 0)
  T.NotOk(status.verified, "the minimum is proven, the rates are not")
end)

T.Case("deposit: one auction per stack for items that are not commodities", function()
  local ns = T.LoadAddon()
  local D = ns.Economy.Deposit
  -- 20 Copper Rods (stacks of 20, merchant price 2): one auction, one minimum.
  T.Eq(D.ForUnits(2, 20, false, nil, 20), 100)
  T.Eq(D.ForUnits(2, 25, false, nil, 20), 200, "a full stack and a partial one")
  T.Eq(D.ForUnits(1000, 3, false, nil, 1), 900, "gear: one auction each")
  T.Eq(D.ForUnits(2, 20, false), 2000, "unknown stack size: one per unit (the old behaviour)")
end)

T.Case("professions are per character on a shared account", function()
  -- Seen in game 2026-11-07: a Rogue saw the Warrior's Blacksmithing as known.
  local who = { name = "Warrior" }
  local extra = { UnitName = function() return who.name end, GetRealmName = function() return "Realm" end }
  local app, ns, clock = craftingApp(nil, extra)
  app:ObserveProfession()
  clock.advance(1)
  local warriorKey = app:CharacterKey()
  T.Eq(warriorKey:match("^[^-]+"), "Warrior")
  local warrior = app.store.db.characters[warriorKey].professions.Mining
  T.Eq(warrior.skill, 23)
  local learnedBefore = #app.opportunities.results.crafting.learned
  T.Ok(learnedBefore >= 1, "the Warrior knows Mining recipes")
  app:OnEvent("NEW_RECIPE_LEARNED", 2)
  clock.advance(1)
  T.Eq(warrior.learned[2], true, "learned by the Warrior")
  T.NotOk(app.store.db.recipes.Mining.list[2].learned, "the shared list keeps the flags it was seen with")
  T.Eq(#app.opportunities.results.crafting.learned, learnedBefore + 1)

  -- The Rogue logs in on the same account, without Mining.
  who.name = "Rogue"
  local rogue, ns2 = craftingApp(nil, extra, app.store.db)
  local rogueKey = rogue:CharacterKey()
  T.Ok(rogue.store.db.characters[rogueKey], "own record")
  T.Eq(#ns2.Data.Recipes.List(), 0, "no Mining recipes for the Rogue")
  T.Eq(next(ns2.Data.Recipes.professions), nil, "no Mining skill in the header")
  T.Eq(rogue.store.db.characters[warriorKey].professions.Mining.learned[2], true, "the Warrior's record is kept")
  T.Eq(ns.Data.Recipes.professions.Mining.skill, 23)
end)

T.Case("professions: lists saved before 1 character per record are given by skill", function()
  local legacy = { schema = 2, recipes = {
    Mining = { at = 5, skill = 23, maxSkill = 75, list = {
      { id = 1, name = "Smelt", profession = "Mining", learned = true, outputs = { { itemID = 9, quantity = 1 } }, reagents = {} },
    } },
    Blacksmithing = { at = 6, skill = 15, maxSkill = 75, list = {
      { id = 7, name = "Rod", profession = "Blacksmithing", learned = true, outputs = { { itemID = 8, quantity = 1 } }, reagents = {} },
    } },
  } }
  local app, ns = Fakes.App({ saved = legacy, globals = {
    UnitName = function() return "Rogue" end, GetRealmName = function() return "Realm" end,
    GetProfessions = function() return 1, nil, nil, nil, 2 end,
    GetProfessionInfo = function(index)
      if index == 1 then return "Mining", 0, 23, 75 end
      return "Cooking", 0, 8, 75
    end,
  } })
  local mine = app.store.db.characters[app:CharacterKey()].professions
  T.Eq(mine.Mining.learned[1], true, "same profession, same skill: given to this character")
  T.Eq(mine.Blacksmithing, nil, "a profession this character does not have stays out")
  T.Eq(mine.Cooking, nil, "nothing saved for Cooking")
  T.Eq(#ns.Data.Recipes.List(), 1)
  T.Eq(ns.Data.Recipes.byId[1].learned, true)
end)

T.Case("crafting: recipes far above the skill are not listed as learnable", function()
  -- In game a Leatherworking 38 Rogue saw Thick Leather and Tanning Rack
  -- (grey at 180 and 145) among the recipes to learn.
  CRAFT_RECIPES[3].trivial = 300
  local app, ns, clock = craftingApp()
  app:ObserveProfession()
  clock.advance(1)
  CRAFT_RECIPES[3].trivial = nil
  local recipe = ns.Data.Recipes.byId[3]
  T.Eq(recipe.trivial, 300, "grey level kept from maxTrivialLevel")
  local crafting = app.opportunities.results.crafting
  T.Eq(crafting.excluded.skill, 1, "Eye Craft (grey at 300) needs more than Mining 23 + 100")
  for _, row in ipairs(crafting.learnable) do T.Ok(row.recipeID ~= 3) end
  local summary = ns.UI.Panels.professions.Summary(app)
  T.Ok(summary:find("1 recipes need more skill", 1, true), summary)
end)

T.Case("crafting: the trainer gives the exact skill and cost of a recipe", function()
  local services = {
    { "Weave Linen", "", "available", "Mining", 20, 150 },
    { "Eye Craft", "", "unavailable", "Mining", 250, 5000 },
    { "Mining", "", "header" },
    { "Sinister Strike", "Rank 2", "available", nil, nil, 100 },
  }
  local app, ns, clock = craftingApp(nil, {
    GetNumTrainerServices = function() return #services end,
    GetTrainerServiceInfo = function(i) local s = services[i] return s[1], s[2], s[3] end,
    GetTrainerServiceSkillReq = function(i) local s = services[i] return s[4], s[5], true end,
    GetTrainerServiceCost = function(i) return services[i][6] end,
  })
  app:ObserveProfession()
  clock.advance(1)
  app:OnEvent("TRAINER_SHOW")
  clock.advance(2)
  local skills = app.store.db.trainer.skills.Mining
  T.Eq(skills["Weave Linen"].skill, 20)
  T.Eq(skills["Weave Linen"].cost, 150)
  T.Eq(skills["Eye Craft"].skill, 250)
  T.Eq(app.store.db.trainer.skills["Sinister Strike"], nil, "class spells have no profession")
  T.Eq(app.store.db.diagnostics.trainer.recorded, 2)
  T.Eq(ns.Data.Recipes.byId[2].requiredSkill, 20)
  local crafting = app.opportunities.results.crafting
  local linen
  for _, row in ipairs(crafting.learnable) do if row.recipeID == 2 then linen = row end end
  T.Ok(linen, "Weave Linen: Mining 23 >= 20, learnable now")
  T.Eq(linen.requires.exact, true)
  T.Eq(linen.requires.cost, 150)
  local tip = table.concat(ns.UI.Panels.professions.Rows(app, { linen })[1].tip, "\n")
  T.Ok(tip:find("Requires Mining 20", 1, true), tip)
  T.Eq(crafting.excluded.skill, 1, "Eye Craft: 250 > 23")
  T.Eq(app:ObserveTrainer(), 0, "same list again: nothing changed")
end)

T.Case("trainer: a client without the trainer API reports it", function()
  local app = Fakes.App({})
  local changed, reason = app:ObserveTrainer()
  T.Eq(changed, nil)
  T.Eq(reason, "no_api")
end)
