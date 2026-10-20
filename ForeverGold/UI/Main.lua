-- Main window: tabs Opportunities, History, Professions, Portfolio,
-- Settings. Analysis only: no button here spends, posts or cancels.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local Main = { tab = "opportunities", offset = 0, rows = {}, filters = { vendor = true, resale = true, allocated = false } }
ns.UI.Main = Main

Main.TABS = { "opportunities", "history", "professions", "portfolio", "settings" }
Main.ROW_HEIGHT = 18
Main.COLUMNS = {
  { key = "item", width = 0.24 }, { key = "strategy", width = 0.10 }, { key = "qty", width = 0.06, right = true },
  { key = "cost", width = 0.11, right = true }, { key = "revenue", width = 0.11, right = true },
  { key = "profit", width = 0.11, right = true }, { key = "roi", width = 0.07, right = true },
  { key = "risk", width = 0.11 }, { key = "age", width = 0.09, right = true },
}

local function L(key) return ns.L[key] or key end

-- Text of one cell for an opportunity.
function Main.Cell(opportunity, key, now)
  if key == "item" then return opportunity.name or opportunity.itemKey end
  if key == "strategy" then return L("STRAT_" .. opportunity.strategy) end
  if key == "qty" then return tostring(opportunity.quantity) end
  if key == "cost" then return Money.Format(opportunity.cost) end
  if key == "revenue" then return Money.Format(opportunity.revenuePrudent) end
  if key == "profit" then return Money.Format(opportunity.profit) end
  if key == "roi" then return opportunity.roi and string.format("%.0f%%", opportunity.roi * 100) or "?" end
  if key == "risk" then
    local c = opportunity.confidence
    return L("CLASS_" .. opportunity.class) .. " " .. (c and c.score or "?")
  end
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
    if strategyOk and budgetOk then list[#list + 1] = opportunity end
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

function Main.StatusLine(app, results)
  local parts = {}
  if results and results.demo then parts[#parts + 1] = W.Color(L("DEMO_BANNER"), W.WARN) end
  local scanner = app and app.scanner
  if Main.progress then
    parts[#parts + 1] = Main.ProgressText(Main.progress)
  elseif scanner then
    parts[#parts + 1] = L("SCAN_STATE") .. " " .. L("STATE_" .. scanner.state)
    if scanner.reason then parts[#parts + 1] = "(" .. (ns.L["REASON_" .. scanner.reason] or scanner.reason) .. ")" end
  end
  if results then
    local c = results.counts
    parts[#parts + 1] = string.format(L("COUNTS"), c.opportunities, c.candidates, c.itemKeys, c.listings, c.units)
    parts[#parts + 1] = L("COVERAGE") .. " " .. L("COVERAGE_" .. tostring(results.coverage))
  end
  return table.concat(parts, "  ")
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
  frame.scanButton:SetEnabled(not active)
  frame.scanButton:SetText(active and L("BTN_SCANNING") or L("BTN_SCAN"))
  frame.status:SetText(Main.StatusLine(app, Main.Results()))
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
  frame.title:SetText("ForeverGold " .. ns.VERSION .. (Main.demoResults and ("  " .. W.Color(L("DEMO_BANNER"), W.WARN)) or ""))
  local list = Main.Visible(results, Main.filters)
  local maxOffset = math.max(0, #list - (Main.visibleRows or 1))
  if Main.offset > maxOffset then Main.offset = maxOffset end
  local now = app and app.clock and app.clock()
  for index = 1, (Main.visibleRows or 0) do
    local row = Main.rows[index]
    local opportunity = list[index + Main.offset]
    row.opportunity = opportunity
    if opportunity then
      for column, spec in ipairs(Main.COLUMNS) do
        row.cells[column]:SetText(Main.Cell(opportunity, spec.key, now))
      end
      row:Show()
    else
      row:Hide()
    end
  end
  frame.empty:SetText(#list == 0 and Main.EmptyReason(app, results) or "")
  frame.denominator:SetText(results and string.format(L("EXCLUDED"), Main.ExcludedText(results)) or "")
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
  scan:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  frame.scanButton = scan
  local cancel = W.Button(panel, L("BTN_CANCEL"), 90, function()
    ns.app.scanner:Cancel("user")
    Main.RefreshTable()
  end)
  cancel:SetPoint("LEFT", scan, "RIGHT", 4, 0)
  local demo = W.Button(panel, L("BTN_DEMO"), 90, function()
    if Main.demoResults then
      Main.demoResults = nil
    else
      Main.demoResults = ns.app:Demo()
    end
    Main.RefreshTable()
  end)
  demo:SetPoint("LEFT", cancel, "RIGHT", 4, 0)
  local vendor = W.Check(panel, L("FILTER_VENDOR"), function(value) Main.filters.vendor = value Main.RefreshTable() end)
  vendor:SetPoint("LEFT", demo, "RIGHT", 10, 0)
  vendor:SetChecked(true)
  local resale = W.Check(panel, L("FILTER_RESALE"), function(value) Main.filters.resale = value Main.RefreshTable() end)
  resale:SetPoint("LEFT", vendor, "RIGHT", 70, 0)
  resale:SetChecked(true)
  local allocated = W.Check(panel, L("FILTER_BUDGET"), function(value) Main.filters.allocated = value Main.RefreshTable() end)
  allocated:SetPoint("LEFT", resale, "RIGHT", 80, 0)

  local bar = CreateFrame("StatusBar", nil, panel)
  bar:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -28)
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
  tableFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -46)
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
  frame:SetSize(820, 460)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetClampedToScreen(true)
  frame:SetMovable(true)
  frame:SetResizable(true)
  if frame.SetResizeBounds then
    frame:SetResizeBounds(640, 320, 1600, 1000)
  elseif frame.SetMinResize then
    frame:SetMinResize(640, 320)
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
