-- Crafting: buy reagents, craft, sell (spec 9.4), phase 4.
--   profitCraft = netOutputRevenue - reagentCost - extraCosts - expectedLostDeposits
-- Reagents already in bags are not free: their opportunity cost is reported
-- separately from the incremental money cost. Bound outputs have no AH value.
local _, ns = ...

local Money = ns.Economy.Money
local Depth = ns.Economy.Depth
local Costs = ns.Economy.Costs
local Crafting = { id = "crafting" }
ns.Strategies.Crafting = Crafting

local function outputPerCraft(recipe, itemID)
  for _, output in ipairs(recipe.outputs) do
    if output.itemID == itemID then return output.quantity end
  end
  return nil
end

-- Whole crafts needed for `needed` units of the recipe's output itemID.
-- Returns { crafts, outputs, reagents = { [itemID] = qty } } or nil, reason.
function Crafting.Plan(recipe, itemID, needed)
  local per = outputPerCraft(recipe, itemID)
  if not Money.IsQuantity(per) then return nil, "output_unknown" end
  if not Money.IsQuantity(needed) then return nil, "quantity" end
  local crafts = math.ceil(needed / per)
  local reagents = {}
  for _, reagent in ipairs(recipe.reagents) do
    if not Money.IsQuantity(reagent.quantity) then return nil, "reagent_unknown" end
    reagents[reagent.itemID] = (reagents[reagent.itemID] or 0) + reagent.quantity * crafts
  end
  return { crafts = crafts, outputs = crafts * per, reagents = reagents }
end

-- Monetary evaluation of a plan.
-- market[itemID] = { levels = {...}, owned = n, ownedValue = copper per unit? }
-- outputPrice: prudent gross unit price for the output (nil = unknown).
function Crafting.Price(plan, market, outputPrice, feeBp, extra)
  local cost, opportunity = 0, 0
  for itemID, quantity in pairs(plan.reagents) do
    local entry = market[itemID] or {}
    local owned = math.min(entry.owned or 0, quantity)
    local toBuy = quantity - owned
    if toBuy > 0 then
      local purchase = Depth.BuyCost(entry.levels or {}, toBuy)
      if not purchase or not purchase.complete then return nil, "reagent_depth" end
      cost = cost + purchase.cost
    end
    if owned > 0 then
      if not Money.IsCopper(entry.ownedValue) then return nil, "owned_value_unknown" end
      opportunity = opportunity + entry.ownedValue * owned
    end
  end
  if not Money.IsCopper(outputPrice) then return nil, "output_price_unknown" end
  local result, reason = Costs.Evaluate({
    B = 0, R = outputPrice * plan.outputs, feeBp = feeBp, L = extra and extra.lostDeposits or 0,
    X = cost + (extra and extra.costs or 0),
  })
  if not result then return nil, reason end
  result.moneyCost = cost
  result.opportunityCost = opportunity
  result.economicProfit = result.profit - opportunity
  return result
end

-- Strategy entry point; ranking arrives with phase 4.
function Crafting.Evaluate(context)
  local recipes = context.recipes or ns.Data.Recipes
  if not recipes or recipes.status ~= "observed" then
    return {}, { recipes_unavailable = 1 }
  end
  return {}, { not_implemented = 1 }
end
