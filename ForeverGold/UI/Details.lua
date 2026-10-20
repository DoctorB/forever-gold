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

-- Plain text body for one opportunity (also used by tests).
function Details.Text(o)
  local lines = {}
  local function add(text) lines[#lines + 1] = text end
  add((o.name or o.itemKey) .. "  [" .. L("STRAT_" .. o.strategy) .. "]  " .. L("CLASS_" .. o.class))
  local c = o.confidence or {}
  local reasons = {}
  for _, reason in ipairs(c.reasons or {}) do reasons[#reasons + 1] = L("RISK_" .. reason) end
  add(string.format(L("DETAIL_CONFIDENCE"), tostring(c.score), L("LABEL_" .. tostring(c.label)),
    #reasons > 0 and table.concat(reasons, "; ") or "-"))
  add("")
  local f = o.formula or {}
  if f.kind == "vendor" then
    add(string.format(L("DETAIL_VENDOR"), o.quantity, fmt(f.sellPrice), fmt(o.revenuePrudent), fmt(f.B), fmt(o.profit)))
  elseif f.kind == "resale" then
    add(string.format(L("DETAIL_RESALE_R"), f.sellUnits, fmt(f.unitPrice), fmt(f.R), fmt(f.reference), tostring(f.window),
      fmt(f.competitor)))
    add(string.format(L("DETAIL_RESALE_F"), Money.FormatBp(f.feeBp), f.feeVerified and L("VERIFIED") or L("SCENARIO")))
    add(string.format(L("DETAIL_RESALE_L"), fmt(f.L), f.depositKnown and "" or L("DEPOSIT_UNKNOWN")))
    add(string.format(L("DETAIL_RESALE_P"), fmt(f.R), Money.FormatBp(f.feeBp), fmt(f.B), fmt(f.L), fmt(f.X), fmt(o.profit)))
    add(string.format(L("DETAIL_BREAKEVEN"), fmt(f.breakEven)))
    if (f.residualUnits or 0) > 0 then add(string.format(L("DETAIL_RESIDUAL"), f.residualUnits)) end
    if o.profitBase then add(string.format(L("DETAIL_BASE"), fmt(o.profitBase), fmt(f.basePrice))) end
  end
  if o.roi then add(string.format(L("DETAIL_ROI"), o.roi * 100)) end
  add("")
  add(L("DETAIL_LOTS"))
  for _, lot in ipairs(o.lots or {}) do
    local listing = lot.listing or {}
    add(string.format("  %d x  %s  (%s/u)%s", lot.quantity, fmt(lot.cost), fmt(listing.unitPrice),
      listing.auctionID and ("  #" .. listing.auctionID) or ""))
  end
  add("")
  local p = o.provenance or {}
  add(string.format(L("DETAIL_SOURCE"), tostring(p.source), tostring(p.scanId), L("COVERAGE_" .. tostring(o.coverage))))
  if Schema.IsVariantUnknown(o.itemKey) then add(L("DETAIL_VARIANT_UNKNOWN")) end
  local constraints = {}
  for _, key in ipairs(o.constraints or {}) do constraints[#constraints + 1] = L("CONSTRAINT_" .. key) end
  add(L("DETAIL_CONSTRAINTS") .. " " .. table.concat(constraints, "; "))
  add(L("DETAIL_ALLOCATION") .. " " .. L("ALLOC_" .. tostring(o.allocation)))
  add("")
  add(L("DETAIL_DISCLAIMER"))
  return table.concat(lines, "\n")
end

function Details.Ensure()
  if Details.frame then return Details.frame end
  local parent = ns.UI.Main.Ensure()
  local frame = CreateFrame("Frame", nil, parent, "BasicFrameTemplateWithInset")
  Details.frame = frame
  frame:SetSize(420, 420)
  frame:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
  frame:EnableMouse(true)
  frame.title = W.Text(frame, "GameFontNormal")
  frame.title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -6)
  frame.title:SetText(L("DETAIL_TITLE"))
  frame.body = W.ScrollText(frame, false)
  frame.body:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -30)
  frame.body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 64)
  frame.result = W.Text(frame, "GameFontHighlightSmall")
  frame.result:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 40)
  frame.result:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
  frame.prepare = W.Button(frame, L("BTN_PREPARE"), 150, function() Details.Prepare() end)
  frame.prepare:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 12)
  frame.refresh = W.Button(frame, L("BTN_REFRESH"), 150, function() Details.Refresh() end)
  frame.refresh:SetPoint("LEFT", frame.prepare, "RIGHT", 6, 0)
  return frame
end

function Details.Show(opportunity)
  local frame = Details.Ensure()
  Details.current = opportunity
  frame.body:SetText(Details.Text(opportunity))
  frame.result:SetText("")
  local demo = ns.UI.Main.demoResults ~= nil
  frame.prepare:SetEnabled(not demo)
  frame.refresh:SetEnabled(not demo)
  frame:Show()
end

function Details.Prepare()
  local opportunity = Details.current
  if not opportunity then return end
  local prepared = ns.app.transactions:Prepare(opportunity)
  Details.frame.result:SetText(string.format(L("PREPARED"), fmt(prepared.total), opportunity.name or opportunity.itemKey))
end

function Details.Refresh()
  local opportunity = Details.current
  local app = ns.app
  if not opportunity then return end
  local prepared = app.transactions.prepared
  if not prepared or prepared.itemKey ~= opportunity.itemKey then prepared = app.transactions:Prepare(opportunity) end
  local itemID = Schema.ItemIDOf(opportunity.itemKey)
  local suffix = tonumber(opportunity.itemKey:match(":(%d+)$"))
  local ok, reason = app.scanner:Search(itemID, suffix, function(_, listings)
    local status, reasons = app.transactions:Revalidate(prepared, listings)
    local text = L("QUOTE_" .. status)
    if #reasons > 0 then
      local localized = {}
      for _, why in ipairs(reasons) do localized[#localized + 1] = L("QUOTE_REASON_" .. why) end
      text = text .. ": " .. table.concat(localized, ", ")
    end
    if Details.frame then Details.frame.result:SetText(text) end
  end)
  if not ok then
    Details.frame.result:SetText(L("SCAN_REFUSED") .. " " .. (ns.L["REASON_" .. reason] or reason))
  else
    Details.frame.result:SetText(L("QUOTE_WAITING"))
  end
end
