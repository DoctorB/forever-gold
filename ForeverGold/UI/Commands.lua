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
  elseif command == "feetest" then
    if rest == "cancel" then
      app.feeTest:Cancel()
    elseif rest == "status" then
      local state = app.feeTest:State()
      ns.Print(state and string.format(L("FT_STATUS"), state.name, L("FT_STAGE_" .. state.stage)) or L("FT_NONE"))
    else
      ns.UI.Feedback.StartFeeTest(app, tonumber(rest))
    end
  elseif command == "crafting" or command == "craft" then
    for _, line in ipairs(Commands.CraftingLines(app, tonumber(rest) or 5)) do ns.Print(line) end
  elseif command == "professions" or command == "prof" then
    -- Read-only: observes the open profession window, if any, then reports.
    app:ObserveProfession()
    local lines = ns.Services.Diagnostics.ProfessionSummary(app.store.db.diagnostics.professions, ns.L)
    for _, line in ipairs(lines) do ns.Print(line) end
    ns.Print(L("DIAG_SAVED"))
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

-- Chat report of the crafting evaluation: the best `limit` recipes the
-- player knows, then the best ones a trainer could teach.
function Commands.CraftingLines(app, limit)
  local fmt = ns.Economy.Money.Format
  local lines = {}
  if ns.Data.Recipes.status ~= "observed" then return { L("CRAFT_NO_RECIPES") } end
  local results = app.opportunities.results
  if not results or results.demo then return { L("CRAFT_NO_SCAN") } end
  local crafting = results.crafting or app.lastCrafting
  if not crafting then
    if not app.craftingRunning then app:EvaluateCrafting() end
    return { L("CRAFT_PENDING") }
  end
  local function name(row)
    local info = app.items:Read(row.outputItemID)
    return (info and info.name) or row.name or ("#" .. tostring(row.recipeID))
  end
  local function rows(list)
    if #list == 0 then
      lines[#lines + 1] = L("CRAFT_NONE")
      return
    end
    for index = 1, math.min(limit, #list) do
      local row = list[index]
      local made = row.quantity > 1 and (row.quantity .. " x ") or ""
      lines[#lines + 1] = string.format(L("CRAFT_ROW"), row.profession or "?", made .. name(row), fmt(row.cost),
        L("CRAFT_EXIT_" .. row.exit), fmt(row.revenue), fmt(row.profit))
    end
  end
  lines[#lines + 1] = string.format(L("CRAFT_HEADER_LEARNED"), #crafting.learned, crafting.counts.evaluated,
    crafting.counts.recipes)
  rows(crafting.learned)
  lines[#lines + 1] = L("CRAFT_HEADER_LEARNABLE")
  rows(crafting.learnable)
  local reasons = {}
  for reason, n in pairs(crafting.excluded) do reasons[#reasons + 1] = (L("CRAFT_WHY_" .. reason)) .. " " .. n end
  table.sort(reasons)
  if #reasons > 0 then lines[#lines + 1] = L("CRAFT_SKIPPED") .. " " .. table.concat(reasons, ", ") end
  return lines
end

-- Registers /fg and /forevergold (the only command globals we add).
function Commands.Register(env)
  if type(env.SlashCmdList) ~= "table" then return false end
  env.SLASH_FOREVERGOLD1 = "/fg"
  env.SLASH_FOREVERGOLD2 = "/forevergold"
  env.SlashCmdList.FOREVERGOLD = Commands.Handle
  return true
end
