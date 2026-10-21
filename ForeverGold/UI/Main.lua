-- Main window: tabs Opportunities, History, Professions, Portfolio,
-- Settings. Analysis only: no button here spends, posts or cancels.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local Main = { tab = "opportunities", offset = 0, rows = {},
  filters = { vendor = true, resale = true, allocated = false, verified = false } }
ns.UI.Main = Main

Main.TABS = { "opportunities", "history", "professions", "portfolio", "settings" }
Main.ROW_HEIGHT = 18
Main.COLUMNS = {
  { key = "item", width = 0.24 }, { key = "strategy", width = 0.19 }, { key = "qty", width = 0.05, right = true },
  { key = "cost", width = 0.10, right = true }, { key = "revenue", width = 0.10, right = true },
  { key = "profit", width = 0.10, right = true }, { key = "roi", width = 0.06, right = true },
  { key = "risk", width = 0.11 }, { key = "age", width = 0.05, right = true },
}

local function L(key) return ns.L[key] or key end

-- Text of one cell for an opportunity.
function Main.Cell(opportunity, key, now)
  if key == "item" then return opportunity.name or opportunity.itemKey end
  if key == "strategy" then return L("ACTION_" .. opportunity.strategy) end
  if key == "qty" then return tostring(opportunity.quantity) end
  if key == "cost" then return Money.Format(opportunity.cost) end
  if key == "revenue" then return Money.Format(opportunity.revenuePrudent) end
  if key == "profit" then return "+" .. Money.Format(opportunity.profit) end
  if key == "roi" then return opportunity.roi and string.format("%.0f%%", opportunity.roi * 100) or "?" end
  if key == "risk" then return L("CLASS_" .. opportunity.class) end
  if key == "age" then
    local seen = opportunity.provenance and opportunity.provenance.seen
    if not seen or not now then return "?" end
    local minutes = math.floor((now - seen) / 60)
    if minutes < 60 then return minutes .. "m" end
    return math.floor(minutes / 60) .. "h"
  end
  return ""
end

-- Filtered list shown in the table.
function Main.Visible(results, filters)
  local list = {}
  for _, opportunity in ipairs(results and results.list or {}) do
    local strategyOk = (opportunity.strategy == "vendor" and filters.vendor)
      or (opportunity.strategy == "resale" and filters.resale)
    local budgetOk = not filters.allocated or opportunity.allocation == "allocated"
    local verifiedOk = not filters.verified or opportunity.class == "vendor_confirmed"
    if strategyOk and budgetOk and verifiedOk then list[#list + 1] = opportunity end
  end
  return list
end

-- Why the table is empty: no data, insufficient data, unsupported, or no deals.
function Main.EmptyReason(app, results)
  if app and app.ah and not app.ah:GetCapabilities().replicate then return L("EMPTY_UNSUPPORTED") end
  if not results or results.counts.itemKeys == 0 then return L("EMPTY_NO_DATA") end
  if (results.excluded.insufficient_history or 0) > 0 and #results.list == 0 then return L("EMPTY_INSUFFICIENT") end
  return L("EMPTY_NO_DEALS")
end

-- "3 min", "2 h".
function Main.Age(seconds)
  if not seconds then return "?" end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then return minutes .. " min" end
  return math.floor(minutes / 60) .. " h"
end

-- Countdown text: "9 min", "40 s".
function Main.Wait(seconds)
  if seconds >= 60 then return math.ceil(seconds / 60) .. " min" end
  return math.ceil(seconds) .. " s"
end

-- One plain line: what the scanner is doing or when the data was read.
-- Technical details (coverage, denominators) live in the History tab.
function Main.StatusLine(app, results)
  if results and results.demo then return W.Color(L("DEMO_BANNER"), W.WARN) end
  if Main.progress then return Main.ProgressText(Main.progress) end
  local scanner = app and app.scanner
  local parts = {}
  if results and results.snapshot and results.snapshot.finished and app and app.clock then
    local c = results.counts
    local age = app.clock() - results.snapshot.finished
    parts[#parts + 1] = string.format(L("STATUS_LAST"), Main.Age(age), c.listings, c.itemKeys)
    if age > 600 then parts[#parts + 1] = L("STATUS_OLD") end
  else
    parts[#parts + 1] = L("STATUS_NEVER")
  end
  if scanner and (scanner.state == "FAILED" or scanner.state == "CANCELLED") and scanner.reason then
    parts[#parts + 1] = L("STATE_" .. scanner.state) .. ": " .. (ns.L["REASON_" .. scanner.reason] or scanner.reason)
  end
  return table.concat(parts, "  ·  ")
end

-- What to do next, in one sentence.
function Main.Hint(app, results, visible)
  if results and results.demo then return L("HINT_DEMO") end
  if app and app.batch and app.batch.active then return L("HINT_BATCH") end
  local wait = app and app.scanner and app.scanner:Cooldown().remaining or 0
  if not results or results.counts.itemKeys == 0 then
    if wait > 0 then return string.format(L("HINT_WAIT"), Main.Wait(wait)) end
    return L("HINT_SCAN")
  end
  if #visible == 0 then
    if wait > 0 then return string.format(L("HINT_NONE_WAIT"), Main.Wait(wait)) end
    return L("HINT_NONE")
  end
  if app and app.store and app.store:Settings().assistedBuy then return L("HINT_CLICK_BUY") end
  return L("HINT_CLICK")
end

-- Short, plain footer about what is hidden and why.
function Main.FooterText(results)
  local parts = {}
  local excluded = results and results.excluded or {}
  if (excluded.below_threshold or 0) > 0 then
    parts[#parts + 1] = string.format(L("FOOTER_SMALL"), excluded.below_threshold)
  end
  if (excluded.stale or 0) > 0 then
    parts[#parts + 1] = string.format(L("FOOTER_STALE"), excluded.stale)
  end
  if (excluded.insufficient_history or 0) > 0 then
    parts[#parts + 1] = string.format(L("FOOTER_HISTORY"), excluded.insufficient_history)
  end
  return table.concat(parts, "  ·  ")
end

-- Lines of the row tooltip.
function Main.RowTooltip(o)
  local lines = { o.name or o.itemKey }
  local key = o.strategy == "vendor" and "TIP_ROW_VENDOR" or "TIP_ROW_RESALE"
  lines[#lines + 1] = string.format(L(key), o.quantity, Money.Format(o.cost), Money.Format(o.revenuePrudent))
  lines[#lines + 1] = string.format(L("TIP_ROW_GAIN"), Money.Format(o.profit))
  lines[#lines + 1] = L("DETAIL_CLASS_" .. o.class)
  lines[#lines + 1] = L("TIP_ROW_CLICK")
  return lines
end

-- Progress of the running scan pipeline: { phase, done?, total? } or nil.
-- Phases: waiting, receiving, read, recheck, history, evaluate.
function Main.ProgressText(progress)
  if not progress then return nil end
  local label = L("PHASE_" .. progress.phase)
  if progress.total and progress.total > 0 then
    if progress.phase == "recheck" then
      return string.format("%s %d/%d", label, progress.done or 0, progress.total)
    end
    return string.format("%s %d/%d (%d%%)", label, progress.done or 0, progress.total,
      math.floor((progress.done or 0) * 100 / progress.total))
  end
  if progress.timeout then
    return string.format("%s... %d s / %d s", label, progress.elapsed or 0, progress.timeout)
  end
  return label .. "..."
end

-- Fraction for the progress bar across the whole pipeline: reading counts
-- for the first 60%, history 20%, analysis 20%.
function Main.ProgressFraction(progress)
  if not progress then return 0 end
  local share = { waiting = { 0, 0 }, receiving = { 0.02, 0 }, read = { 0.02, 0.58 }, recheck = { 0.6, 0 },
    history = { 0.6, 0.2 }, evaluate = { 0.8, 0.2 } }
  local s = share[progress.phase] or { 0, 0 }
  local part = 0
  if progress.total and progress.total > 0 then part = (progress.done or 0) / progress.total end
  return s[1] + s[2] * part
end

function Main.SetProgress(progress)
  Main.progress = progress
  Main.UpdateProgress()
end

function Main.UpdateProgress()
  local frame = Main.frame
  if not frame or not frame:IsShown() or not frame.progressBar then return end
  local progress = Main.progress
  local app = ns.app
  local active = progress ~= nil or (app and app.scanner and app.scanner:IsActive())
  if active then
    frame.progressBar:SetValue(Main.ProgressFraction(progress))
    frame.progressText:SetText(Main.ProgressText(progress) or L("PHASE_waiting") .. "...")
    frame.progressBar:Show()
  else
    frame.progressBar:Hide()
  end
  local wait = (not active and app and app.scanner) and app.scanner:Cooldown().remaining or 0
  frame.scanButton:SetEnabled(not active and wait <= 0)
  if active then
    frame.scanButton:SetText(L("BTN_SCANNING"))
  elseif wait > 0 then
    frame.scanButton:SetText(string.format(L("BTN_SCAN_WAIT"), Main.Wait(wait)))
  else
    frame.scanButton:SetText(L("BTN_SCAN"))
  end
  frame.status:SetText(Main.StatusLine(app, Main.Results()))
  ns.UI.PurchasePanel.UpdateBatchButton()
end

Main.CLASS_COLORS = { vendor_confirmed = W.EMERALD, prudent = W.GOLD, speculative = W.MUTED }

-- Whether the player can pay for at least part of an opportunity.
function Main.Affordable(opportunity, money)
  if not money then return true end
  if opportunity.commodity == true then
    local cheapest
    for _, lot in ipairs(opportunity.lots or {}) do
      local unit = lot.listing and lot.listing.unitPrice
      if unit and (not cheapest or unit < cheapest) then cheapest = unit end
    end
    return cheapest ~= nil and cheapest <= money
  end
  for _, lot in ipairs(opportunity.lots or {}) do
    if lot.cost <= money then return true end
  end
  return false
end

-- Headline that tells at a glance whether a real gain is available.
-- Returns text, colour.
function Main.Banner(results, money)
  local totals = {}
  for _, opportunity in ipairs(results and results.list or {}) do
    local t = totals[opportunity.class] or { n = 0, profit = 0, capital = 0, affordable = 0 }
    t.n, t.profit, t.capital = t.n + 1, t.profit + opportunity.profit, t.capital + (opportunity.capital or 0)
    if Main.Affordable(opportunity, money) then t.affordable = t.affordable + 1 end
    totals[opportunity.class] = t
  end
  local suffix = money and string.format(L("BANNER_MONEY"), Money.Format(money)) or ""
  local confirmed, prudent = totals.vendor_confirmed, totals.prudent
  if confirmed then
    return string.format(L("BANNER_VERIFIED"), Money.Format(confirmed.profit), confirmed.n) .. suffix, W.EMERALD
  elseif prudent then
    return string.format(L("BANNER_PROBABLE"), Money.Format(prudent.profit), prudent.n) .. suffix, W.GOLD
  elseif totals.speculative then
    return L("BANNER_SPECULATIVE") .. suffix, W.MUTED
  end
  return L("BANNER_NONE") .. suffix, W.MUTED
end

function Main.Results()
  if Main.demoResults then return Main.demoResults end
  local app = ns.app
  return app and app.opportunities and app.opportunities.results
end

-- Left padding of a column: left-aligned text after a right-aligned column
-- gets a wider gap so headers such as "ROI" and "Class/score" stay apart.
function Main.Pad(spec)
  return spec.right and 2 or 12
end

local function layoutRows()
  local frame = Main.frame
  local tableFrame = frame.table
  local width = tableFrame:GetWidth() or 600
  local height = tableFrame:GetHeight() or 300
  local count = math.max(1, math.floor(height / Main.ROW_HEIGHT) - 1)
  for index = 1, math.max(count, #Main.rows) do
    local row = Main.rows[index]
    if not row and index <= count then
      row = CreateFrame("Button", nil, tableFrame)
      row:SetHeight(Main.ROW_HEIGHT)
      row.cells = {}
      for column = 1, #Main.COLUMNS do
        row.cells[column] = W.Text(row, "GameFontHighlightSmall", Main.COLUMNS[column].right and "RIGHT" or "LEFT")
      end
      local highlight = row:CreateTexture(nil, "HIGHLIGHT")
      highlight:SetAllPoints()
      highlight:SetColorTexture(1, 0.82, 0.2, 0.12)
      row:SetScript("OnClick", function() if row.opportunity then ns.UI.Details.Show(row.opportunity) end end)
      row:SetScript("OnEnter", function()
        if not row.opportunity or type(GameTooltip) ~= "table" then return end
        GameTooltip:SetOwner(row, "ANCHOR_CURSOR")
        for index, line in ipairs(Main.RowTooltip(row.opportunity)) do
          if index == 1 then GameTooltip:SetText(line) else GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true) end
        end
        GameTooltip:Show()
      end)
      row:SetScript("OnLeave", function() if type(GameTooltip) == "table" then GameTooltip:Hide() end end)
      Main.rows[index] = row
    end
    if row then
      if index <= count then
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", 0, -index * Main.ROW_HEIGHT)
        row:SetPoint("RIGHT", tableFrame, "RIGHT", 0, 0)
        local x = 0
        for column, spec in ipairs(Main.COLUMNS) do
          local cell = row.cells[column]
          cell:ClearAllPoints()
          cell:SetPoint("LEFT", row, "LEFT", x + Main.Pad(spec), 0)
          cell:SetWidth(width * spec.width - Main.Pad(spec) - 4)
          x = x + width * spec.width
        end
      else
        row:Hide()
      end
    end
  end
  Main.visibleRows = count
  local x = 0
  for column, spec in ipairs(Main.COLUMNS) do
    local header = frame.headers[column]
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", tableFrame, "TOPLEFT", x + Main.Pad(spec), 0)
    header:SetWidth(width * spec.width - Main.Pad(spec) - 4)
    x = x + width * spec.width
  end
end

function Main.RefreshTable()
  local frame = Main.frame
  if not frame or not frame:IsShown() then return end
  local app = ns.app
  local results = Main.Results()
  frame.status:SetText(Main.StatusLine(app, results))
  frame.title:SetText("Forever Gold " .. ns.VERSION .. (Main.demoResults and ("  " .. W.Color(L("DEMO_BANNER"), W.WARN)) or ""))
  local list = Main.Visible(results, Main.filters)
  local maxOffset = math.max(0, #list - (Main.visibleRows or 1))
  if Main.offset > maxOffset then Main.offset = maxOffset end
  local now = app and app.clock and app.clock()
  local money = app and app.client and app.client:Money()
  local bannerText, bannerColor = Main.Banner(results, money)
  frame.banner:SetText(bannerText)
  frame.banner:SetTextColor(bannerColor[1], bannerColor[2], bannerColor[3])
  for index = 1, (Main.visibleRows or 0) do
    local row = Main.rows[index]
    local opportunity = list[index + Main.offset]
    row.opportunity = opportunity
    if opportunity then
      local color = Main.CLASS_COLORS[opportunity.class] or W.MUTED
      if not Main.Affordable(opportunity, money) then color = W.MUTED end
      for column, spec in ipairs(Main.COLUMNS) do
        local cell = row.cells[column]
        cell:SetText(Main.Cell(opportunity, spec.key, now))
        local c = color
        if spec.key == "profit" and opportunity.profit > 0 and color ~= W.MUTED then c = W.EMERALD end
        if spec.key ~= "item" and spec.key ~= "profit" and spec.key ~= "risk" then c = { 0.9, 0.9, 0.9 } end
        cell:SetTextColor(c[1], c[2], c[3])
      end
      row:Show()
    else
      row:Hide()
    end
  end
  frame.empty:SetText(#list == 0 and Main.EmptyReason(app, results) or "")
  frame.denominator:SetText(Main.FooterText(results))
  frame.hint:SetText(Main.Hint(app, results, list))
  Main.UpdateProgress()
end

function Main.ExcludedText(results)
  local parts = {}
  for reason, count in pairs(results.excluded or {}) do
    parts[#parts + 1] = (ns.L["EXCL_" .. reason] or reason) .. " " .. count
  end
  table.sort(parts)
  return #parts > 0 and table.concat(parts, ", ") or "0"
end

-- Refreshes a side tab if it is the one on screen.
function Main.RefreshPanel(tab)
  local frame = Main.frame
  if frame and frame:IsShown() and Main.tab == tab and ns.UI.Panels[tab] then
    ns.UI.Panels[tab].Refresh(frame.panels[tab])
  end
end

function Main.SelectTab(tab)
  Main.tab = tab
  local frame = Main.frame
  for _, name in ipairs(Main.TABS) do
    local panel = frame.panels[name]
    if panel then
      if name == tab then panel:Show() else panel:Hide() end
    end
    frame.tabs[name]:SetEnabled(name ~= tab)
  end
  if tab == "opportunities" then
    Main.RefreshTable()
  elseif ns.UI.Panels[tab] then
    ns.UI.Panels[tab].Refresh(frame.panels[tab])
  end
end

local function buildOpportunities(panel)
  local frame = Main.frame
  local scan = W.Button(panel, L("BTN_SCAN"), 110, function()
    Main.demoResults = nil
    ns.UI.Feedback.StartScan(ns.app)
    Main.RefreshTable()
  end)
  frame.banner = W.Text(panel, "GameFontNormalLarge")
  frame.banner:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  frame.banner:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  frame.hint = W.Text(panel, "GameFontHighlight")
  frame.hint:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -22)
  frame.hint:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  scan:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -44)
  frame.scanButton = scan
  local cancel = W.Button(panel, L("BTN_CANCEL"), 90, function()
    if ns.app.batch.active then
      ns.app.batch:Cancel()
    else
      ns.app.scanner:Cancel("user")
    end
    Main.RefreshTable()
  end)
  cancel:SetPoint("LEFT", scan, "RIGHT", 4, 0)
  -- Demo stays available with /fg demo; this slot is the "Buy all" button.
  local batch = ns.UI.PurchasePanel.BuildBatchButton(panel)
  batch:SetPoint("LEFT", cancel, "RIGHT", 4, 0)
  frame.batchButton = batch
  local vendor = W.Check(panel, L("FILTER_VENDOR"), function(value) Main.filters.vendor = value Main.RefreshTable() end)
  vendor:SetPoint("LEFT", batch, "RIGHT", 10, 0)
  vendor:SetChecked(true)
  local resale = W.Check(panel, L("FILTER_RESALE"), function(value) Main.filters.resale = value Main.RefreshTable() end)
  resale:SetPoint("LEFT", vendor, "RIGHT", 70, 0)
  resale:SetChecked(true)
  local allocated = W.Check(panel, L("FILTER_BUDGET"), function(value) Main.filters.allocated = value Main.RefreshTable() end)
  allocated:SetPoint("LEFT", resale, "RIGHT", 80, 0)
  local verified = W.Check(panel, L("FILTER_VERIFIED"), function(value) Main.filters.verified = value Main.RefreshTable() end)
  verified:SetPoint("LEFT", allocated, "RIGHT", 90, 0)

  local bar = CreateFrame("StatusBar", nil, panel)
  bar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -72)
  bar:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  bar:SetHeight(14)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(W.GOLD[1], W.GOLD[2], W.GOLD[3])
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)
  local back = bar:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(0, 0, 0, 0.5)
  frame.progressText = W.Text(bar, "GameFontHighlightSmall", "CENTER")
  frame.progressText:SetPoint("CENTER", bar, "CENTER", 0, 0)
  bar:Hide()
  frame.progressBar = bar

  local tableFrame = CreateFrame("Frame", nil, panel)
  tableFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -90)
  tableFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 18)
  tableFrame:EnableMouseWheel(true)
  tableFrame:SetScript("OnMouseWheel", function(_, delta)
    Main.offset = math.max(0, Main.offset - delta * 3)
    Main.RefreshTable()
  end)
  tableFrame:SetScript("OnSizeChanged", function()
    layoutRows()
    Main.RefreshTable()
  end)
  frame.table = tableFrame
  frame.headers = {}
  for column, spec in ipairs(Main.COLUMNS) do
    local header = W.Text(tableFrame, "GameFontNormalSmall", spec.right and "RIGHT" or "LEFT")
    header:SetText(L("COL_" .. spec.key))
    frame.headers[column] = header
  end
  frame.empty = W.Text(tableFrame, "GameFontDisable", "CENTER")
  frame.empty:SetPoint("CENTER", tableFrame, "CENTER", 0, 0)
  frame.denominator = W.Text(panel, "GameFontDisableSmall")
  frame.denominator:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 2)
  frame.denominator:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
end

function Main.Ensure()
  if Main.frame then return Main.frame end
  local frame = CreateFrame("Frame", "ForeverGoldMainFrame", UIParent, "BasicFrameTemplateWithInset")
  Main.frame = frame
  -- New frames start shown: hide until Toggle/Open decides.
  frame:Hide()
  frame:SetSize(900, 500)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(820, 360, 1600, 1000)
  elseif frame.SetMinResize then
    frame:SetMinResize(820, 360)
  end
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  if type(UISpecialFrames) == "table" then table.insert(UISpecialFrames, "ForeverGoldMainFrame") end

  frame.title = W.Text(frame, "GameFontNormal", "LEFT")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -6)
  frame.status = W.Text(frame, "GameFontHighlightSmall")
  frame.status:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -56)
  frame.status:SetPoint("RIGHT", frame, "RIGHT", -14, 0)

  frame.tabs, frame.panels = {}, {}
  local previous
  for _, name in ipairs(Main.TABS) do
    local tab = W.Button(frame, L("TAB_" .. name), 120, function() Main.SelectTab(name) end)
    if previous then
      tab:SetPoint("LEFT", previous, "RIGHT", 4, 0)
    else
      tab:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -28)
    end
    frame.tabs[name] = tab
    previous = tab
    local panel = CreateFrame("Frame", nil, frame)
    panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -74)
    panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 22)
    panel:Hide()
    frame.panels[name] = panel
  end
  buildOpportunities(frame.panels.opportunities)
  for name, builder in pairs(ns.UI.Panels) do
    if frame.panels[name] then builder.Build(frame.panels[name]) end
  end

  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)

  local version = W.Text(frame, "GameFontDisableSmall", "LEFT")
  version:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 6)
  version:SetText(L("FOOTER"))

  frame:SetScript("OnShow", function() Main.SelectTab(Main.tab) end)
  -- Once a second while open: countdown on the scan button, data age.
  local elapsedSince = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSince = elapsedSince + (elapsed or 0)
    if elapsedSince >= 1 then
      elapsedSince = 0
      Main.UpdateProgress()
    end
  end)
  layoutRows()
  return frame
end

function Main.Toggle()
  local frame = Main.Ensure()
  if frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
    Main.SelectTab(Main.tab)
  end
end

function Main.Open(tab)
  local frame = Main.Ensure()
  frame:Show()
  Main.SelectTab(tab or Main.tab)
end
