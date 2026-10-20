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

T.Case("scan with the window closed: a few chat lines tell what happens", function()
  withClient(function(ns, _, clock, ah, eventFrame)
    eventFrame.scripts.OnEvent(eventFrame, "AUCTION_HOUSE_SHOW")
    local before = #ns.printed
    ns.UI.Commands.Handle("scan")
    T.Ok(ns.printed[#ns.printed]:find(ns.L.FB_REQUESTED, 1, true) ~= nil, "requested")
    ah.delivered = true
    eventFrame.scripts.OnEvent(eventFrame, "REPLICATE_ITEM_LIST_UPDATE")
    T.Ok(ns.printed[#ns.printed]:find(ns.L.FB_RECEIVING, 1, true) ~= nil, "receiving")
    clock.advance(60)
    local text = table.concat(ns.printed, "\n", before + 1)
    T.Ok(text:find(string.format(ns.L.FB_READING, 1), 1, true) ~= nil, "reading rows")
    T.Ok(text:find("1 item keys, 1 rows, 20 units", 1, true) ~= nil, "outcome with counts: " .. text)
    T.Ok(text:find("analysis done: 1 opportunities", 1, true) ~= nil, "analysis")
    T.Ok(#ns.printed - before <= 8, "few lines, got " .. (#ns.printed - before))
  end)
end)

T.Case("scan with the window open: progress bar while working, button disabled", function()
  withClient(function(ns, _, clock, ah, eventFrame)
    local rows = {}
    for index = 1, 600 do rows[index] = { itemID = 1000 + index, count = 1, buyout = 100 } end
    ah.rows = rows
    ns.UI.Commands.Handle("")
    local frame = ns.UI.Main.frame
    T.NotOk(frame.progressBar.shown, "hidden when idle")
    eventFrame.scripts.OnEvent(eventFrame, "AUCTION_HOUSE_SHOW")
    ns.UI.Commands.Handle("scan")
    T.Ok(frame.progressBar.shown)
    T.NotOk(frame.scanButton.enabled, "scan button disabled")
    T.Eq(frame.scanButton:GetText(), ns.L.BTN_SCANNING)
    ah.delivered = true
    eventFrame.scripts.OnEvent(eventFrame, "REPLICATE_ITEM_LIST_UPDATE")
    clock.advance(2.5)
    T.Eq(ns.UI.Main.progress.phase, "read")
    T.Ok(frame.progressText:GetText():find(ns.L.PHASE_read, 1, true) ~= nil)
    local value = frame.progressBar:GetValue()
    T.Ok(value > 0 and value < 0.6, "reading share: " .. tostring(value))
    clock.advance(120)
    T.NotOk(frame.progressBar.shown, "hidden when done")
    T.Ok(frame.scanButton.enabled)
    T.Eq(ns.UI.Main.progress, nil)
  end)
end)

T.Case("progress text and fraction", function()
  withClient(function(ns)
    local Main = ns.UI.Main
    T.Eq(Main.ProgressText({ phase = "read", done = 250, total = 1000 }), ns.L.PHASE_read .. " 250/1000 (25%)")
    T.Eq(Main.ProgressText({ phase = "recheck", done = 2, total = 4 }), ns.L.PHASE_recheck .. " 2/4")
    T.Eq(Main.ProgressText({ phase = "receiving" }), ns.L.PHASE_receiving .. "...")
    T.Eq(Main.ProgressFraction({ phase = "evaluate", done = 50, total = 100 }), 0.9)
    T.Eq(Main.ProgressText(nil), nil)
  end)
end)

T.Case("waiting shows elapsed time; silence explains the cooldown; refusal says when", function()
  withClient(function(ns, _, clock, ah, eventFrame)
    ns.UI.Commands.Handle("")
    eventFrame.scripts.OnEvent(eventFrame, "AUCTION_HOUSE_SHOW")
    ns.UI.Commands.Handle("scan")
    ah.delivered = true
    eventFrame.scripts.OnEvent(eventFrame, "REPLICATE_ITEM_LIST_UPDATE")
    clock.advance(120)
    ah.delivered = false
    -- No prior measurement: forget the seeded bounds.
    ns.app.scanner.memory.lowerBound, ns.app.scanner.memory.upperBound = nil, nil
    clock.advance(400)
    ns.UI.Commands.Handle("scan")
    clock.advance(5)
    T.Ok(ns.UI.Main.frame.progressText:GetText():find("5 s / 60 s", 1, true) ~= nil, ns.UI.Main.frame.progressText:GetText())
    clock.advance(60)
    local last = ns.printed[#ns.printed]
    T.Ok(last:find("no answer from the server in 60 s", 1, true) ~= nil, last)
    T.Ok(last:find("no answer up to 8 min 40 s", 1, true) ~= nil, last)
    ns.UI.Commands.Handle("scan")
    last = ns.printed[#ns.printed]
    T.Ok(last:find("next attempt possible in 3 min 55 s", 1, true) ~= nil, last)
    T.Eq(ah.replicateCalls, 2)
  end)
end)

T.Case("durations read naturally", function()
  withClient(function(ns)
    local D = ns.UI.Feedback.Duration
    T.Eq(D(45), "45 s")
    T.Eq(D(606), "10 min 6 s")
    T.Eq(D(900), "15 min")
  end)
end)

T.Case("with the measured cooldown a scan too early is refused before sending", function()
  withClient(function(ns, _, clock, ah, eventFrame)
    eventFrame.scripts.OnEvent(eventFrame, "AUCTION_HOUSE_SHOW")
    ns.UI.Commands.Handle("scan")
    ah.delivered = true
    eventFrame.scripts.OnEvent(eventFrame, "REPLICATE_ITEM_LIST_UPDATE")
    clock.advance(600) -- 10 min after the answered request
    ns.UI.Commands.Handle("scan")
    local last = ns.printed[#ns.printed]
    T.Ok(last:find("still cooling down: next scan possible in 3 min 34 s", 1, true) ~= nil, last)
    T.Ok(last:find("between 13 min 34 s and 16 min", 1, true) ~= nil, last)
    T.Eq(ah.replicateCalls, 1)
    clock.advance(215)
    ns.UI.Commands.Handle("scan")
    T.Eq(ah.replicateCalls, 2, "allowed once the proven bound has passed")
  end)
end)
