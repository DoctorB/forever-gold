-- History, Professions and Portfolio tabs. History and Portfolio show their
-- data as tables (UI/Table.lua); the row builders are pure and tested.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local MarketValue = ns.Economy.MarketValue
local Schema = ns.Data.Schema
local Store = ns.Data.Store
ns.UI.Panels = ns.UI.Panels or {}
local Panels = ns.UI.Panels

local function L(key) return ns.L[key] or key end
local fmt = Money.Format

local function age(seconds)
  return ns.UI.Main.Age(seconds)
end

local function signed(copper)
  if copper > 0 then return "+" .. fmt(copper), W.EMERALD end
  if copper < 0 then return fmt(copper), W.WARN end
  return fmt(0), nil
end

-- History ------------------------------------------------------------------

local History = {}
Panels.history = History

History.SCAN_COLUMNS = {
  { key = "time", width = 0.16 }, { key = "mode", width = 0.22 }, { key = "result", width = 0.16 },
  { key = "auctions", width = 0.12, right = true }, { key = "items", width = 0.12, right = true },
  { key = "units", width = 0.12, right = true }, { key = "duration", width = 0.10, right = true },
}
History.PRICE_COLUMNS = {
  { key = "item", width = 0.32 }, { key = "ref", width = 0.15, right = true }, { key = "days", width = 0.13, right = true },
  { key = "min", width = 0.14, right = true }, { key = "depth", width = 0.13, right = true },
  { key = "seen", width = 0.13, right = true },
}
History.PRICE_LIMIT = 300

function History.SummaryLine(app)
  local store = app.store
  local market = store:Market(app:MarketKey(), false)
  local bytes = Store.EstimateBytes(store.db.markets)
  local persistence = ns.Core.Capabilities.IsVerified("persistence") and L("VERIFIED") or L("NOT_VERIFIED")
  if store.sessionOnly then persistence = L("SESSION_ONLY") end
  local fields = app.client:MarketFields()
  local where = (fields.realm or "?") .. (fields.faction and (" (" .. fields.faction .. ")") or "")
  return string.format(L("HIST_SUMMARY"), where, market and market.itemCount or 0, math.floor(bytes / 1024),
    math.floor(Store.RETENTION.budgetBytes / 1024), persistence)
end

-- Rows for the scans table, newest first.
function History.ScanRows(app)
  local market = app.store:Market(app:MarketKey(), false)
  local rows = {}
  local snapshots = market and market.snapshots or {}
  for index = #snapshots, 1, -1 do
    local s = snapshots[index]
    local counts = s.counts or {}
    local full = s.coverage == "full_verified" or s.coverage == "full_unverified"
    rows[#rows + 1] = {
      cells = {
        app.client:FormatTime(s.t), L("MODE_" .. tostring(s.mode)), L(full and "HIST_RESULT_full" or "HIST_RESULT_partial"),
        tostring(counts.valid or counts.rows or "-"), tostring(s.items or 0), tostring(counts.units or "-"),
        s.started and (math.max(0, s.t - s.started) .. " s") or "-",
      },
      colors = { [3] = full and W.EMERALD or W.GOLD },
    }
  end
  return rows
end

-- Rows for the prices table: the most recently seen item keys first.
function History.PriceRows(app, limit)
  local market = app.store:Market(app:MarketKey(), false)
  local rows = {}
  if not market then return rows end
  local keys = {}
  for itemKey, item in pairs(market.items) do keys[#keys + 1] = { key = itemKey, seen = item.lastSeen or 0 } end
  table.sort(keys, function(a, b)
    if a.seen ~= b.seen then return a.seen > b.seen end
    return a.key < b.key
  end)
  local now = app.clock()
  for index = 1, math.min(#keys, limit or History.PRICE_LIMIT) do
    local itemKey = keys[index].key
    local item = market.items[itemKey]
    local series = app.history:Series(app:MarketKey(), itemKey)
    local estimate = MarketValue.EstimateSeries(series, now)
    local info = app.items and app.items:Read(Schema.ItemIDOf(itemKey))
    local last = item.recent and item.recent[#item.recent] or {}
    local ready = estimate.status == "ok"
    rows[#rows + 1] = {
      cells = {
        info and info.name or itemKey, ready and fmt(estimate.reference) or "-", tostring(#series),
        fmt(last.min), tostring(last.depth or "-"), item.lastSeen and age(now - item.lastSeen) or "-",
      },
      colors = { [3] = ready and W.EMERALD or W.MUTED },
      tip = { info and info.name or itemKey, itemKey, ready and string.format(L("PRICE_TIP_REF"), estimate.window)
        or L("PRICE_TIP_WAIT") },
    }
  end
  return rows
end

local function columnsWithLabels(columns, prefix)
  local labelled = {}
  for index, column in ipairs(columns) do
    labelled[index] = { key = column.key, width = column.width, right = column.right, label = L(prefix .. column.key) }
  end
  return labelled
end

function History.Build(panel)
  panel.summary = W.Text(panel, "GameFontHighlightSmall")
  panel.summary:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  panel.summary:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  local scansTitle = W.Text(panel, "GameFontNormal")
  scansTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -20)
  scansTitle:SetText(L("HIST_SCANS"))
  panel.scans = ns.UI.Table.New(panel, columnsWithLabels(History.SCAN_COLUMNS, "HIST_COL_"))
  panel.scans.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -38)
  panel.scans.frame:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  panel.scans.frame:SetHeight(18 * 6)
  local pricesTitle = W.Text(panel, "GameFontNormal")
  pricesTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -152)
  pricesTitle:SetText(L("HIST_PRICES"))
  panel.prices = ns.UI.Table.New(panel, columnsWithLabels(History.PRICE_COLUMNS, "PRICE_COL_"))
  panel.prices.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -170)
  panel.prices.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 30)

  -- Export/import box, shown only when used (over the prices table).
  panel.exchange = W.ScrollText(panel, true)
  panel.exchange:SetPoint("TOPLEFT", panel.prices.frame, "TOPLEFT", 0, 0)
  panel.exchange:SetPoint("BOTTOMRIGHT", panel.prices.frame, "BOTTOMRIGHT", 0, 0)
  panel.exchange:Hide()
  local function showBox(visible)
    if visible then
      panel.exchange:Show()
      panel.prices.frame:Hide()
    else
      panel.exchange:Hide()
      panel.prices.frame:Show()
    end
  end
  local export = W.Button(panel, L("BTN_EXPORT"), 100, function()
    showBox(true)
    panel.exchange:SetText(ns.Data.Exchange.Export(ns.app.store, ns.app:MarketKey()))
    panel.exchange.edit:HighlightText()
    panel.message:SetText(L("EXPORT_HINT"))
  end)
  export:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
  local import = W.Button(panel, L("BTN_IMPORT"), 100, function()
    if not panel.exchange:IsShown() then
      showBox(true)
      panel.exchange:SetText("")
      panel.message:SetText(L("IMPORT_PASTE"))
      return
    end
    local report = ns.Data.Exchange.Import(ns.app.store, panel.exchange:GetText(), ns.app:MarketKey())
    if report.ok then
      panel.message:SetText(string.format(L("IMPORT_OK"), report.added, report.skipped))
      showBox(false)
    else
      panel.message:SetText(W.Color(string.format(L("IMPORT_FAIL"), report.error, report.line or 0), W.WARN))
    end
    History.Refresh(panel)
  end)
  import:SetPoint("LEFT", export, "RIGHT", 6, 0)
  local close = W.Button(panel, L("BTN_CLOSE"), 80, function()
    showBox(false)
    panel.message:SetText("")
  end)
  close:SetPoint("LEFT", import, "RIGHT", 6, 0)
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
  reset:SetPoint("LEFT", close, "RIGHT", 6, 0)
  panel.message = W.Text(panel, "GameFontHighlightSmall")
  panel.message:SetPoint("LEFT", reset, "RIGHT", 10, 0)
  panel.message:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
end

function History.Refresh(panel)
  local app = ns.app
  panel.summary:SetText(History.SummaryLine(app))
  panel.scans:SetRows(History.ScanRows(app), L("HIST_EMPTY_SCANS"))
  panel.prices:SetRows(History.PriceRows(app), L("HIST_EMPTY_PRICES"))
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

Portfolio.COLUMNS = {
  { key = "date", width = 0.12 }, { key = "item", width = 0.22 }, { key = "qty", width = 0.06, right = true },
  { key = "paid", width = 0.10, right = true }, { key = "sold", width = 0.08, right = true },
  { key = "received", width = 0.10, right = true }, { key = "gain", width = 0.10, right = true },
  { key = "bags", width = 0.08, right = true }, { key = "status", width = 0.14 },
}

-- Four headline figures: { label, value, color }.
function Portfolio.Cards(report)
  local t = report.totals
  local gain, gainColor = signed(t.realized)
  return {
    { label = L("PORT_CARD_GAIN"), value = gain, color = gainColor or W.GOLD },
    { label = L("PORT_CARD_SPENT"), value = fmt(t.spent), color = { 0.9, 0.9, 0.9 } },
    { label = L("PORT_CARD_RECEIVED"), value = fmt(t.revenue), color = { 0.9, 0.9, 0.9 } },
    { label = string.format(L("PORT_CARD_PENDING"), t.pendingUnits), value = fmt(t.pendingExpected),
      color = t.pendingUnits > 0 and W.GOLD or W.MUTED },
  }
end

-- Rows of the purchases table, newest first.
function Portfolio.Rows(report, formatTime)
  local rows = {}
  for _, e in ipairs(report.entries) do
    local gain, gainColor = signed(e.realized or 0)
    local status
    if e.status == "uncertain" then
      status = "PORT_STATUS_uncertain"
    elseif e.remaining == 0 then
      status = "PORT_STATUS_sold"
    elseif e.sold > 0 then
      status = "PORT_STATUS_partial"
    else
      status = "PORT_STATUS_bags"
    end
    local uncertain = e.status == "uncertain"
    rows[#rows + 1] = {
      cells = {
        formatTime(e.t), e.name or "?", tostring(e.quantity), fmt(e.cost), uncertain and "-" or tostring(e.sold),
        uncertain and "-" or fmt(e.revenue), (uncertain or e.sold == 0) and "-" or gain,
        uncertain and "-" or tostring(e.remaining), L(status),
      },
      colors = {
        [7] = (not uncertain and e.sold > 0) and gainColor or nil,
        [9] = uncertain and W.WARN or (e.remaining == 0 and W.EMERALD or W.GOLD),
      },
    }
  end
  return rows
end

-- One line under the cards: what to do next, budget in short.
function Portfolio.Note(app, report)
  local t = report.totals
  local parts = {}
  if t.uncertain > 0 then parts[#parts + 1] = string.format(L("PORT_UNCERTAIN"), t.uncertain) end
  if t.pendingUnits > 0 then parts[#parts + 1] = L("PORT_HOWTO_SELL") end
  local settings = app.store:Settings()
  if Money.IsCopper(settings.budget) then
    parts[#parts + 1] = string.format(L("PORT_BUDGET_SHORT"), fmt(settings.budget), fmt(settings.maxPurchase))
  else
    parts[#parts + 1] = string.format(L("PORT_LIMIT_SHORT"), fmt(settings.maxPurchase))
  end
  return table.concat(parts, "  ·  ")
end

-- Plain-text summary (chat and tests).
function Portfolio.Summary(app)
  local report = ns.Services.Portfolio.Report(app.store.db.ledger)
  local lines = {}
  for _, card in ipairs(Portfolio.Cards(report)) do lines[#lines + 1] = card.label .. ": " .. card.value end
  lines[#lines + 1] = Portfolio.Note(app, report)
  return table.concat(lines, "\n")
end

function Portfolio.Build(panel)
  panel.cards = {}
  for index = 1, 4 do
    local label = W.Text(panel, "GameFontNormalSmall")
    local value = W.Text(panel, "GameFontNormalLarge")
    panel.cards[index] = { label = label, value = value }
  end
  panel.note = W.Text(panel, "GameFontHighlightSmall")
  panel.note:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -46)
  panel.note:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  local labelled = {}
  for index, column in ipairs(Portfolio.COLUMNS) do
    labelled[index] = { key = column.key, width = column.width, right = column.right, label = L("PORT_COL_" .. column.key) }
  end
  panel.table = ns.UI.Table.New(panel, labelled)
  panel.table.frame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -70)
  panel.table.frame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
end

function Portfolio.Refresh(panel)
  local app = ns.app
  local report = ns.Services.Portfolio.Report(app.store.db.ledger)
  local width = panel:GetWidth() or 800
  for index, card in ipairs(Portfolio.Cards(report)) do
    local slot = panel.cards[index]
    local x = (index - 1) * width / 4
    slot.label:ClearAllPoints()
    slot.label:SetPoint("TOPLEFT", panel, "TOPLEFT", x, 0)
    slot.label:SetText(card.label)
    slot.value:ClearAllPoints()
    slot.value:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -16)
    slot.value:SetText(card.value)
    slot.value:SetTextColor(card.color[1], card.color[2], card.color[3])
  end
  panel.note:SetText(Portfolio.Note(app, report))
  panel.table:SetRows(Portfolio.Rows(report, function(t) return app.client:FormatTime(t) end), L("PORT_EMPTY"))
end
