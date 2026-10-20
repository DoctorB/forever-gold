-- History, Professions and Portfolio tabs.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local Store = ns.Data.Store
ns.UI.Panels = ns.UI.Panels or {}
local Panels = ns.UI.Panels

local function L(key) return ns.L[key] or key end

-- History ------------------------------------------------------------------

local History = {}
Panels.history = History

function History.Summary(app)
  local store = app.store
  local lines = {}
  local marketKey = app:MarketKey()
  lines[#lines + 1] = L("HIST_MARKET") .. " " .. marketKey
  local bytes = Store.EstimateBytes(store.db.markets)
  lines[#lines + 1] = string.format(L("HIST_SIZE"), math.floor(bytes / 1024), math.floor(Store.RETENTION.budgetBytes / 1024))
  local persistence = ns.Core.Capabilities.IsVerified("persistence") and L("VERIFIED") or L("NOT_VERIFIED")
  if store.sessionOnly then persistence = L("SESSION_ONLY") end
  lines[#lines + 1] = L("HIST_PERSISTENCE") .. " " .. persistence
  for key, market in pairs(store.db.markets) do
    lines[#lines + 1] = string.format(L("HIST_MARKET_LINE"), key, market.itemCount or 0, #(market.snapshots or {}))
  end
  local market = store:Market(marketKey, false)
  if market then
    lines[#lines + 1] = ""
    lines[#lines + 1] = L("HIST_SNAPSHOTS")
    for index = #market.snapshots, math.max(1, #market.snapshots - 9), -1 do
      local s = market.snapshots[index]
      lines[#lines + 1] = string.format("  %s  %s  %s  %d", tostring(s.id), tostring(s.mode),
        L("COVERAGE_" .. tostring(s.coverage)), s.items or 0)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = L("HIST_NOTE")
  return table.concat(lines, "\n")
end

function History.Build(panel)
  panel.text = W.ScrollText(panel, false)
  panel.text:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  panel.text:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 150)
  panel.exchange = W.ScrollText(panel, true)
  panel.exchange:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, 120)
  panel.exchange:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 30)
  local export = W.Button(panel, L("BTN_EXPORT"), 100, function()
    panel.exchange:SetText(ns.Data.Exchange.Export(ns.app.store, ns.app:MarketKey()))
    panel.exchange.edit:HighlightText()
  end)
  export:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
  local import = W.Button(panel, L("BTN_IMPORT"), 100, function()
    local report = ns.Data.Exchange.Import(ns.app.store, panel.exchange:GetText(), ns.app:MarketKey())
    if report.ok then
      panel.message:SetText(string.format(L("IMPORT_OK"), report.added, report.skipped))
    else
      panel.message:SetText(W.Color(string.format(L("IMPORT_FAIL"), report.error, report.line or 0), W.WARN))
    end
    History.Refresh(panel)
  end)
  import:SetPoint("LEFT", export, "RIGHT", 6, 0)
  local reset = W.Button(panel, L("BTN_RESET_MARKET"), 160, function(button)
    if panel.confirming then
      ns.app.store:Reset("history", ns.app:MarketKey())
      panel.confirming = false
      button:SetText(L("BTN_RESET_MARKET"))
      History.Refresh(panel)
    else
      panel.confirming = true
      button:SetText(L("BTN_CONFIRM"))
    end
  end)
  reset:SetPoint("LEFT", import, "RIGHT", 6, 0)
  panel.message = W.Text(panel, "GameFontHighlightSmall")
  panel.message:SetPoint("LEFT", reset, "RIGHT", 10, 0)
  panel.message:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
end

function History.Refresh(panel)
  panel.text:SetText(History.Summary(ns.app))
end

-- Professions ----------------------------------------------------------------

local Professions = {}
Panels.professions = Professions

function Professions.Summary(app)
  local caps = app.professions:GetCapabilities()
  local lines = {
    L("PROF_DISABLED"),
    "",
    string.format(L("PROF_API"), caps.recipeInfo and L("PRESENT") or L("ABSENT"),
      caps.recipeSchematic and L("PRESENT") or L("ABSENT")),
    string.format(L("PROF_DE"), ns.Data.Disenchant.status),
    string.format(L("PROF_RECIPES"), ns.Data.Recipes.status),
  }
  return table.concat(lines, "\n")
end

function Professions.Build(panel)
  panel.text = W.ScrollText(panel, false)
  panel.text:SetAllPoints()
end

function Professions.Refresh(panel)
  panel.text:SetText(Professions.Summary(ns.app))
end

-- Portfolio ------------------------------------------------------------------

local Portfolio = {}
Panels.portfolio = Portfolio

function Portfolio.Summary(app)
  local settings = app.store:Settings()
  local lines = {}
  if Money.IsCopper(settings.budget) then
    lines[#lines + 1] = string.format(L("PORT_BUDGET"), Money.Format(settings.budget), Money.FormatBp(settings.reserveBp),
      Money.FormatBp(settings.maxItemBp), Money.FormatBp(settings.maxCategoryBp))
  else
    lines[#lines + 1] = L("PORT_NO_BUDGET")
  end
  local results = app.opportunities.results
  if results then
    local allocated, capital = 0, 0
    for _, opportunity in ipairs(results.list) do
      if opportunity.allocation == "allocated" then
        allocated = allocated + 1
        capital = capital + opportunity.capital
      end
    end
    lines[#lines + 1] = string.format(L("PORT_ALLOCATED"), allocated, Money.Format(capital))
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = string.format(L("PORT_LEDGER"), #app.store.db.ledger)
  return table.concat(lines, "\n")
end

function Portfolio.Build(panel)
  panel.text = W.ScrollText(panel, false)
  panel.text:SetAllPoints()
end

function Portfolio.Refresh(panel)
  panel.text:SetText(Portfolio.Summary(ns.app))
end
