-- Tooltips: one line with the local reference price and its sample count.
-- Read-only; any error or secret value leaves the tooltip unchanged.
local _, ns = ...

local Money = ns.Economy.Money
local MarketValue = ns.Economy.MarketValue
local Schema = ns.Data.Schema
local Tooltips = {}
ns.UI.Tooltips = Tooltips

local function L(key) return ns.L[key] or key end

-- Text for an item link, or nil when there is nothing to say.
function Tooltips.Line(app, link)
  local itemID, suffix, bonus = Schema.VariantFromLink(link)
  if not itemID then return nil end
  local itemKey = Schema.ItemKey(itemID, suffix, false, bonus)
  local estimate = MarketValue.Estimate(app.history, itemKey, app:MarketKey(), app.clock())
  if estimate.status ~= "ok" then
    if (estimate.samples[30] or 0) == 0 then return nil end
    return string.format(L("TIP_INSUFFICIENT"), estimate.samples[30])
  end
  return string.format(L("TIP_REFERENCE"), Money.Format(estimate.reference), estimate.window, estimate.samples[estimate.window])
end

local function onItem(tooltip)
  local app = ns.app
  if not app or not app.loaded or type(tooltip.GetItem) ~= "function" then return end
  local ok, _, link = pcall(tooltip.GetItem, tooltip)
  if not ok or type(link) ~= "string" or app.client:IsSecret(link) then return end
  local okLine, line = pcall(Tooltips.Line, app, link)
  if okLine and line then tooltip:AddLine("|cffe6b422ForeverGold|r " .. line, 0.9, 0.9, 0.9) end
end

function Tooltips.Install(env)
  if Tooltips.installed then return end
  local processor = env.TooltipDataProcessor
  local enum = env.Enum and env.Enum.TooltipDataType
  if type(processor) == "table" and type(processor.AddTooltipPostCall) == "function" and enum and enum.Item then
    processor.AddTooltipPostCall(enum.Item, function(tooltip) onItem(tooltip) end)
    Tooltips.installed = "processor"
  elseif type(env.GameTooltip) == "table" and type(env.GameTooltip.HookScript) == "function" then
    pcall(env.GameTooltip.HookScript, env.GameTooltip, "OnTooltipSetItem", onItem)
    Tooltips.installed = "hook"
  end
end
