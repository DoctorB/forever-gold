-- UI smoke test on a frame mock: the addon loads as in the client (Init.lua
-- runs), ADDON_LOADED is simulated, every tab and the details view build.
-- Catches nil calls and missing strings; says nothing about real layout.

local function withClient(fn)
  local clock = Fakes.Clock()
  local ah = Fakes.AuctionHouse({ { itemID = 101, count = 20, buyout = 700 } })
  local globals = Fakes.Env(clock, ah, { items = { [101] = { name = "Linen", sellPrice = 50 } } })
  globals.math = nil -- keep the real math library
  for key, value in pairs(Fakes.UIGlobals()) do globals[key] = value end
  local saved = {}
  for key in pairs(globals) do saved[key] = _G[key] end
  local ok, err = pcall(function()
    local ns = T.LoadAddon({ globals = globals, keepGlobals = true })
    local eventFrame = globals.created[1]
    T.Ok(eventFrame and eventFrame.events.ADDON_LOADED, "event frame registered ADDON_LOADED")
    eventFrame.scripts.OnEvent(eventFrame, "ADDON_LOADED", "SomeOtherAddon")
    T.NotOk(ns.app.loaded, "ignores other addons")
    eventFrame.scripts.OnEvent(eventFrame, "ADDON_LOADED", "ForeverGold")
    fn(ns, globals, clock, ah, eventFrame)
  end)
  for key, value in pairs(saved) do _G[key] = value end
  _G.ForeverGoldDB, _G.SLASH_FOREVERGOLD1, _G.SLASH_FOREVERGOLD2 = nil, nil, nil
  if not ok then error(err, 0) end
end

T.Case("loads like the client and registers commands and events", function()
  withClient(function(ns, globals, _, _, eventFrame)
    T.Ok(ns.app.loaded)
    T.Eq(type(_G.ForeverGoldDB), "table")
    T.Eq(_G.ForeverGoldDB.schema, 1)
    T.Eq(globals.SlashCmdList.FOREVERGOLD, ns.UI.Commands.Handle)
    T.Eq(_G.SLASH_FOREVERGOLD1, "/fg")
    T.Ok(eventFrame.events.AUCTION_HOUSE_SHOW)
    T.Ok(eventFrame.events.REPLICATE_ITEM_LIST_UPDATE)
    T.Eq(#ns.app.events.rejected, 0)
  end)
end)

T.Case("every tab builds and refreshes; demo rows and details render", function()
  withClient(function(ns)
    ns.UI.Commands.Handle("")
    local frame = ns.UI.Main.frame
    T.Ok(frame and frame:IsShown())
    for _, tab in ipairs(ns.UI.Main.TABS) do ns.UI.Main.SelectTab(tab) end
    ns.UI.Main.SelectTab("opportunities")
    T.Ok(frame.empty:GetText():find(ns.L.EMPTY_NO_DATA, 1, true) ~= nil)
    ns.UI.Commands.Handle("demo")
    T.Ok(frame.status:GetText():find(ns.L.DEMO_BANNER, 1, true) ~= nil, "demo labelled")
    local first = ns.UI.Main.rows[1]
    T.Ok(first.opportunity ~= nil, "demo row shown")
    first.scripts.OnClick()
    local details = ns.UI.Details.frame
    T.Ok(details:IsShown())
    T.NotOk(details.prepare.enabled, "no preparation on demo data")
    T.Ok(details.body.text:find("DEMO", 1, true) ~= nil)
  end)
end)

T.Case("details text expands the resale formula with scenario labels", function()
  withClient(function(ns)
    local results = ns.app:Demo()
    local resale
    for _, o in ipairs(results.list) do if o.strategy == "resale" then resale = o end end
    local text = ns.UI.Details.Text(resale)
    T.Ok(text:find(ns.L.SCENARIO, 1, true) ~= nil, "fee shown as scenario")
    T.Ok(text:find(ns.L.DETAIL_DISCLAIMER, 1, true) ~= nil)
    T.Ok(text:find("x (1 - 5.0%)", 1, true) ~= nil, "formula expanded")
  end)
end)

T.Case("settings validate all inputs before applying any", function()
  withClient(function(ns)
    local settings = ns.app.store:Settings()
    local ok, invalid = ns.UI.Settings.Apply(settings, { budget = "100", feeBp = "abc", minRoiBp = "20" })
    T.NotOk(ok)
    T.Eq(invalid[1], "feeBp")
    T.Eq(settings.budget, nil, "nothing applied")
    T.Ok(ns.UI.Settings.Apply(settings, { budget = "100", feeBp = "5", minRoiBp = "20", minProfit = "10" }))
    T.Eq(settings.budget, 1000000)
    T.Eq(settings.feeBp, 500)
    T.Eq(settings.minRoiBp, 2000)
    T.Eq(settings.minProfit, 1000)
    T.Ok(ns.UI.Settings.Apply(settings, { budget = "" }))
    T.Eq(settings.budget, nil)
  end)
end)

T.Case("a scan through the client event frame updates the open window", function()
  withClient(function(ns, _, clock, ah, eventFrame)
    ns.UI.Commands.Handle("")
    eventFrame.scripts.OnEvent(eventFrame, "AUCTION_HOUSE_SHOW")
    ns.UI.Commands.Handle("scan")
    ah.delivered = true
    eventFrame.scripts.OnEvent(eventFrame, "REPLICATE_ITEM_LIST_UPDATE")
    clock.advance(30)
    local first = ns.UI.Main.rows[1]
    T.Ok(first.opportunity and first.opportunity.strategy == "vendor")
    T.Ok(ns.UI.Main.frame.status:GetText():find(ns.L.STATE_PARTIAL, 1, true) ~= nil)
    T.Eq(ah.spendCalls, 0)
  end)
end)

T.Case("tooltip line stays silent without history", function()
  withClient(function(ns)
    T.Eq(ns.UI.Tooltips.Line(ns.app, "|Hitem:101::::::::|h[Linen]|h"), nil)
  end)
end)
