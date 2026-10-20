-- Details: expanded formula, sources, lots, constraints and the reasons
-- behind the confidence score. "Prepare" builds a summary and never spends;
-- "Refresh quote" runs a read-only targeted search and revalidates it.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local Schema = ns.Data.Schema
local Details = {}
ns.UI.Details = Details

local function L(key) return ns.L[key] or key end
local fmt = Money.Format

-- Plain text body for one opportunity (also used by tests): what you gain,
-- how reliable it is, what to do; then the calculation for who wants it.
function Details.Text(o)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  add((o.name or o.itemKey) .. "  [" .. L("ACTION_" .. o.strategy) .. "]  " .. L("CLASS_" .. o.class))
  local gain = string.format(L("DETAIL_GAIN"), "+" .. fmt(o.profit))
  add(o.class == "speculative" and gain or W.Color(gain, o.class == "vendor_confirmed" and W.EMERALD or W.GOLD))
  add(L("DETAIL_CLASS_" .. o.class))
  if o.pending then add(W.Color(L("DETAIL_PENDING_" .. o.pending), W.GOLD)) end
  if Schema.IsVariantUnknown(o.itemKey) then add(L("DETAIL_VARIANT_UNKNOWN")) end
  add("")
  add(L("DETAIL_HOWTO"))
  add(string.format(L("DETAIL_STEP_BUY"), o.quantity, o.name or o.itemKey, fmt(o.cost)))
  if o.strategy == "vendor" then
    add(string.format(L("DETAIL_STEP_VENDOR"), fmt(o.revenuePrudent)))
  else
    add(string.format(L("DETAIL_STEP_RELIST"), fmt(o.formula and o.formula.unitPrice)))
  end
  if o.commodity == true then add(L("DETAIL_COMMODITY")) end
  add("")
  add(L("DETAIL_CALC"))
  local f = o.formula or {}
  if f.kind == "vendor" then
    add(string.format(L("DETAIL_VENDOR"), o.quantity, fmt(f.sellPrice), fmt(o.revenuePrudent), fmt(f.B), fmt(o.profit)))
  elseif f.kind == "resale" then
    add(string.format(L("DETAIL_RESALE_R"), f.sellUnits, fmt(f.unitPrice), fmt(f.R), fmt(f.reference), tostring(f.window),
      fmt(f.competitor)))
    add(string.format(L("DETAIL_RESALE_F"), Money.FormatBp(f.feeBp), f.feeVerified and L("VERIFIED") or L("SCENARIO")))
    add(string.format(L("DETAIL_RESALE_L"), fmt(f.L), f.depositKnown and "" or L("DEPOSIT_UNKNOWN")))
    add(string.format(L("DETAIL_RESALE_P"), fmt(f.R), Money.FormatBp(f.feeBp), fmt(f.B), fmt(f.L), fmt(f.X), fmt(o.profit)))
    if (f.residualUnits or 0) > 0 then add(string.format(L("DETAIL_RESIDUAL"), f.residualUnits)) end
  end
  add(L("DETAIL_LOTS"))
  local lots = o.lots or {}
  for index = 1, math.min(#lots, 6) do
    local lot = lots[index]
    add(string.format("  %d x  %s  (%s/u)", lot.quantity, fmt(lot.cost), fmt(lot.listing and lot.listing.unitPrice)))
  end
  if #lots > 6 then add(string.format(L("DETAIL_MORE_LOTS"), #lots - 6)) end
  add("")
  add(L("DETAIL_DISCLAIMER"))
  return table.concat(lines, "\n")
end

function Details.Ensure()
  if Details.frame then return Details.frame end
  local parent = ns.UI.Main.Ensure()
  local frame = CreateFrame("Frame", nil, parent, "BasicFrameTemplateWithInset")
  Details.frame = frame
  frame:SetSize(440, 520)
  frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
  frame:EnableMouse(true)
  frame.title = W.Text(frame, "GameFontNormal")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -6)
  frame.title:SetText(L("DETAIL_TITLE"))
  frame.body = W.ScrollText(frame, false)
  frame.body:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30)
  frame.body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 160)
  ns.UI.PurchasePanel.Build(frame)
  return frame
end

function Details.Show(opportunity)
  local frame = Details.Ensure()
  Details.current = opportunity
  frame.body:SetText(Details.Text(opportunity))
  frame:Show()
  ns.UI.PurchasePanel.Show(opportunity)
end
