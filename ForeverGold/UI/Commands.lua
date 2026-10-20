-- Slash commands: /fg [scan | cancel | diagnostics | demo | reset | help].
-- No command spends, posts, crafts or cancels anything on the AH.
local _, ns = ...

local Commands = {}
ns.UI.Commands = Commands

local function L(key) return ns.L[key] or key end

function Commands.Handle(input)
  local app = ns.app
  local command, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if not app or not app.loaded then
    ns.Print(L("NOT_LOADED"))
    return
  end
  if command == "" then
    ns.UI.Main.Toggle()
  elseif command == "scan" then
    -- Refusal, progress and outcome are reported by UI/Feedback.
    ns.UI.Feedback.StartScan(app)
  elseif command == "cancel" then
    app.scanner:Cancel("user")
    ns.Print(L("SCAN_CANCELLED"))
  elseif command == "diagnostics" or command == "diag" then
    local report = app.diagnostics:Run()
    for _, line in ipairs(ns.Services.Diagnostics.Summary(report, ns.L)) do ns.Print(line) end
    ns.Print(L("DIAG_SAVED"))
    if rest == "ui" then ns.UI.Main.Open("settings") end
  elseif command == "demo" then
    ns.UI.Main.demoResults = app:Demo()
    ns.UI.Main.Open("opportunities")
  elseif command == "probe" then
    ns.UI.Feedback.StartProbe(app)
  elseif command == "lang" then
    local code = ({ it = "itIT", itit = "itIT", en = "enUS", enus = "enUS", auto = "auto" })[rest]
    if not code then
      ns.Print(L("LANG_USAGE"))
      return
    end
    app.store:Settings().locale = code
    ns.ApplyLocale(code)
    ns.Print(L("LANG_SET"))
  elseif command == "reset" then
    ns.UI.Main.Open("history")
    ns.Print(L("RESET_HINT"))
  else
    for _, line in ipairs({ L("HELP_1"), L("HELP_2"), L("HELP_3"), L("HELP_4"), L("HELP_5") }) do ns.Print(line) end
  end
end

-- Registers /fg and /forevergold (the only command globals we add).
function Commands.Register(env)
  if type(env.SlashCmdList) ~= "table" then return false end
  env.SLASH_FOREVERGOLD1 = "/fg"
  env.SLASH_FOREVERGOLD2 = "/forevergold"
  env.SlashCmdList.FOREVERGOLD = Commands.Handle
  return true
end
