-- Init: client glue, last in the TOC. Creates the event frame, loads the
-- SavedVariables after our own ADDON_LOADED and forwards client events.
-- Offline (no CreateFrame) it does nothing; tests drive App directly.
local addonName, ns = ...

local env = _G
if type(env.CreateFrame) ~= "function" then return end

local app = ns.Core.App.New(env)
ns.app = app

local frame = env.CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGOUT")

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= addonName then return end
    frame:UnregisterEvent("ADDON_LOADED")
    env.ForeverGoldDB = app:Load(env.ForeverGoldDB)
    local registered, rejected = app.client:RegisterEvents(frame, ns.Compat.ClientAdapter.EVENTS)
    app.events.registered, app.events.rejected = registered, rejected
    ns.UI.Commands.Register(env)
    ns.UI.Tooltips.Install(env)
    app.bus:Subscribe("scanner.state", function() ns.UI.Main.RefreshTable() end)
    app.bus:Subscribe("opportunities.updated", function() ns.UI.Main.RefreshTable() end)
    return
  end
  local ok, err = pcall(app.OnEvent, app, event, ...)
  if not ok then app:Log(event .. ": " .. tostring(err)) end
end)
