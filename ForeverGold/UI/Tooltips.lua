-- Tooltips: the local reference price and its sample count, the crafting
-- gain when the item is made by one of the player's recipes, and the
-- merchant price when a visited merchant sells it. Read-only; any error or
-- secret value leaves the tooltip unchanged.
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

-- Best crafting row that makes itemID (known recipes first), or nil.
function Tooltips.CraftRow(app, itemID)
  local crafting = app.opportunities and app.opportunities.results and app.opportunities.results.crafting
    or app.lastCrafting
  if not crafting then return nil end
  for _, list in ipairs({ crafting.learned or {}, crafting.learnable or {} }) do
    for _, row in ipairs(list) do
      if row.outputItemID == itemID then return row end
    end
  end
  return nil
end

-- Every line for an item link (may be empty).
-- "12", "0.5", "< 0.1" units per hour.
function Tooltips.Rate(perHour)
  if perHour >= 10 then return string.format("%d", math.floor(perHour + 0.5)) end
  if perHour >= 0.1 then return string.format("%.1f", perHour) end
  return "< 0.1"
end

function Tooltips.Lines(app, link)
  local lines = {}
  local line = Tooltips.Line(app, link)
  if line then lines[#lines + 1] = line end
  local itemID = Schema.VariantFromLink(link)
  if not itemID then return lines end
  local row = Tooltips.CraftRow(app, itemID)
  if row and row.run then
    lines[#lines + 1] = string.format(L(row.learned and "TIP_CRAFT_KNOWN" or "TIP_CRAFT_LEARN"),
      Money.Format(row.run.profit), row.run.crafts, row.name or "?")
  end
  local sales = app.sellThrough and app.sellThrough:Stats(Schema.ItemKey(itemID, 0))
  if sales then
    lines[#lines + 1] = string.format(L("TIP_SALES"), Tooltips.Rate(sales.perHour), Money.Format(sales.clearPrice or 0),
      math.floor(sales.hours + 0.5))
  end
  local merchant = app.MerchantPrice and app:MerchantPrice(itemID)
  if merchant then lines[#lines + 1] = string.format(L("TIP_MERCHANT"), Money.Format(merchant)) end
  return lines
end

local function onItem(tooltip)
  local app = ns.app
  if not app or not app.loaded or type(tooltip.GetItem) ~= "function" then return end
  local ok, _, link = pcall(tooltip.GetItem, tooltip)
  if not ok or type(link) ~= "string" or app.client:IsSecret(link) then return end
  local okLines, lines = pcall(Tooltips.Lines, app, link)
  if not okLines then return end
  for _, line in ipairs(lines) do tooltip:AddLine("|cffe6b422Forever Gold|r " .. line, 0.9, 0.9, 0.9) end
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
