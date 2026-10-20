-- Settings tab: budget and thresholds (all declared product choices, not
-- universal advice), fee scenario, notifications, session mode and the
-- diagnostics report.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local Settings = {}
ns.UI.Settings = Settings
ns.UI.Panels = ns.UI.Panels or {}
ns.UI.Panels.settings = Settings

local function L(key) return ns.L[key] or key end

-- Field definitions: key in settings, unit, bounds (in display units).
Settings.FIELDS = {
  { key = "budget", label = "SET_BUDGET", unit = "gold", min = 0, max = 10000000, optional = true },
  { key = "reserveBp", label = "SET_RESERVE", unit = "percent", min = 0, max = 90 },
  { key = "maxItemBp", label = "SET_MAX_ITEM", unit = "percent", min = 1, max = 100 },
  { key = "maxCategoryBp", label = "SET_MAX_CATEGORY", unit = "percent", min = 1, max = 100 },
  { key = "minRoiBp", label = "SET_MIN_ROI", unit = "percent", min = 0, max = 1000 },
  { key = "minProfit", label = "SET_MIN_PROFIT", unit = "silver", min = 0, max = 10000000 },
  { key = "feeBp", label = "SET_FEE", unit = "percent", min = 0, max = 50 },
  { key = "bufferBp", label = "SET_BUFFER", unit = "percent", min = 0, max = 50 },
  { key = "maxPurchase", label = "SET_MAX_PURCHASE", unit = "silver", min = 0, max = 10000000 },
  { key = "minVendorProfit", label = "SET_MIN_VENDOR_PROFIT", unit = "copper", min = 1, max = 10000000 },
  { key = "minVendorRoiBp", label = "SET_MIN_VENDOR_ROI", unit = "percent", min = 0, max = 1000 },
}

local function toDisplay(field, value)
  if value == nil then return "" end
  if field.unit == "gold" then return tostring(value / Money.COPPER_PER_GOLD) end
  if field.unit == "silver" then return tostring(value / Money.COPPER_PER_SILVER) end
  if field.unit == "copper" then return tostring(value) end
  return tostring(value / 100)
end

local function fromDisplay(field, text)
  text = (text or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub(",", ".")
  if text == "" then
    if field.optional then return nil, true end
    return nil, false
  end
  local number = tonumber(text)
  if not number or number ~= number or number < field.min or number > field.max then return nil, false end
  if field.unit == "gold" then return math.floor(number * Money.COPPER_PER_GOLD + 0.5), true end
  if field.unit == "silver" then return math.floor(number * Money.COPPER_PER_SILVER + 0.5), true end
  if field.unit == "copper" then return math.floor(number + 0.5), true end
  return math.floor(number * 100 + 0.5), true
end

-- Validates every input first, then applies all or nothing.
-- values: key -> text. Returns ok, list of invalid keys.
function Settings.Apply(settings, values)
  local parsed, invalid = {}, {}
  for _, field in ipairs(Settings.FIELDS) do
    if values[field.key] ~= nil then
      local value, ok = fromDisplay(field, values[field.key])
      if ok then parsed[field.key] = { value = value } else invalid[#invalid + 1] = field.key end
    end
  end
  if #invalid > 0 then return false, invalid end
  for key, entry in pairs(parsed) do settings[key] = entry.value end
  return true, invalid
end

function Settings.Build(panel)
  panel.inputs = {}
  local y = 0
  -- One field per row: labels are full sentences and must not be cut.
  for index, field in ipairs(Settings.FIELDS) do
    if index > 1 then y = y - 24 end
    local label = W.Text(panel, "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y - 4)
    label:SetWidth(420)
    label:SetText(L(field.label))
    local input = W.Input(panel, 90)
    input:SetPoint("TOPLEFT", panel, "TOPLEFT", 430, y)
    panel.inputs[field.key] = input
  end
  y = y - 30
  panel.notify = W.Check(panel, L("SET_NOTIFY"), function(value) ns.app.store:Settings().notify = value end)
  panel.notify:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
  panel.session = W.Check(panel, L("SET_SESSION"), function(value) ns.app.store:Settings().sessionOnly = value end)
  panel.session:SetPoint("TOPLEFT", panel, "TOPLEFT", 380, y)
  y = y - 26
  panel.assisted = W.Check(panel, L("SET_ASSISTED"), function(value) ns.app.store:Settings().assistedBuy = value end)
  panel.assisted:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
  panel.italian = W.Check(panel, L("SET_ITALIAN"), function(value)
    local code = value and "itIT" or "enUS"
    ns.app.store:Settings().locale = code
    ns.ApplyLocale(code)
    ns.Print(L("LANG_SET"))
  end)
  panel.italian:SetPoint("TOPLEFT", panel, "TOPLEFT", 380, y)
  y = y - 30
  local save = W.Button(panel, L("BTN_SAVE"), 110, function()
    local values = {}
    for key, input in pairs(panel.inputs) do values[key] = input:GetText() end
    local ok, invalid = Settings.Apply(ns.app.store:Settings(), values)
    if ok then
      panel.message:SetText(L("SAVED"))
      ns.app:EvaluateChunked()
    else
      panel.message:SetText(W.Color(L("INVALID") .. " " .. table.concat(invalid, ", "), W.WARN))
    end
  end)
  save:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y)
  local diagnostics = W.Button(panel, L("BTN_DIAGNOSTICS"), 130, function()
    local report = ns.app.diagnostics:Run()
    panel.output:SetText(table.concat(ns.Services.Diagnostics.Summary(report, ns.L), "\n"))
  end)
  diagnostics:SetPoint("LEFT", save, "RIGHT", 6, 0)
  local sample = W.Button(panel, L("BTN_SAMPLE"), 160, function()
    local count = ns.app.diagnostics:SampleListings(ns.app.opportunities.latest)
    panel.message:SetText(string.format(L("SAMPLED"), count))
  end)
  sample:SetPoint("LEFT", diagnostics, "RIGHT", 6, 0)
  local probe = W.Button(panel, L("BTN_PROBE"), 160, function() ns.UI.Feedback.StartProbe(ns.app) end)
  probe:SetPoint("LEFT", sample, "RIGHT", 6, 0)
  local feeTest = W.Button(panel, L("BTN_FEETEST"), 200, function() ns.UI.Feedback.StartFeeTest(ns.app) end)
  feeTest:SetPoint("LEFT", probe, "RIGHT", 6, 0)
  panel.message = W.Text(panel, "GameFontHighlightSmall")
  panel.message:SetPoint("LEFT", feeTest, "RIGHT", 10, 0)
  panel.message:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  panel.output = W.ScrollText(panel, false)
  panel.output:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, y - 30)
  panel.output:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
  panel.output:SetText(L("FEE_NOTE"))
end

function Settings.Refresh(panel)
  local settings = ns.app.store:Settings()
  for _, field in ipairs(Settings.FIELDS) do
    panel.inputs[field.key]:SetText(toDisplay(field, settings[field.key]))
  end
  panel.notify:SetChecked(settings.notify and true or false)
  panel.session:SetChecked(settings.sessionOnly and true or false)
  panel.assisted:SetChecked(settings.assistedBuy and true or false)
  panel.italian:SetChecked(ns.L == ns.Locales.itIT)
end
