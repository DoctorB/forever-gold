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

-- Strategy entry point for the per-item pipeline: crafting spans several
-- items, so it runs once over all recipes (Crafting.EvaluateRecipes).
function Crafting.Evaluate(context)
  local recipes = context.recipes or ns.Data.Recipes
  if not recipes or recipes.status ~= "observed" then
    return {}, { recipes_unavailable = 1 }
  end
  return {}, {}
end

local MarketValue = ns.Economy.MarketValue

-- Best exit for `quantity` crafted units of one output.
-- market: { levels, sellPrice?, estimate? }. Returns { exit, net, gross, fee }
-- for the merchant and for the AH (history-based or, without three days of
-- history, the lowest current listing), the better one first; nil if none.
function Crafting.Exits(market, quantity, settings)
  local exits = {}
  local sellPrice = market and market.sellPrice
  if Money.IsCopper(sellPrice) and sellPrice > 0 then
    local gross = Money.Mul(sellPrice, quantity)
    exits[#exits + 1] = { exit = "vendor", gross = gross, net = gross, fee = 0 }
  end
  -- A bound output (bind on pickup) cannot be sold on the AH.
  if market and market.bound then
    table.sort(exits, function(a, b) return a.net > b.net end)
    return exits[1], exits
  end
  local levels = market and market.levels or {}
  local feeBp = settings.feeBp or 500
  local resale = market and market.estimate and MarketValue.PrudentResale({
    estimate = market.estimate, remaining = levels, units = quantity, bufferBp = settings.bufferBp,
  })
  if resale and resale.sellUnits == quantity then
    local net, fee = Costs.NetRevenue(resale.prudentGross, feeBp)
    if net then exits[#exits + 1] = { exit = "ah", gross = resale.prudentGross, net = net, fee = fee } end
  elseif not resale then
    local lowest = Depth.LowestUnit(levels)
    if lowest then
      local unit = lowest - Money.ShareUp(lowest, settings.bufferBp or 0)
      local gross = Money.Mul(unit, quantity)
      local net, fee = Costs.NetRevenue(gross, feeBp)
      if net and net > 0 then exits[#exits + 1] = { exit = "ah_now", gross = gross, net = net, fee = fee } end
    end
  end
  table.sort(exits, function(a, b) return a.net > b.net end)
  return exits[1], exits
end

-- One recipe, one craft: reagents bought on the AH at their real depth, the
-- output sold at its best exit. market(itemID) -> { levels, sellPrice?, estimate? } or nil;
-- cache: per-run table shared by all recipes (reagent costs by item and quantity).
-- Returns a row, or nil, reason.
function Crafting.EvaluateRecipe(recipe, market, settings, cache)
  local output = recipe.outputs and recipe.outputs[1]
  if not output or not Money.IsQuantity(output.quantity) then return nil, "output_unknown" end
  local cost, reagents = 0, {}
  for _, reagent in ipairs(recipe.reagents or {}) do
    local key = reagent.itemID .. "x" .. reagent.quantity
    local purchase = cache[key]
    if purchase == nil then
      local entry = market(reagent.itemID)
      local levels = entry and entry.levels
      purchase = levels and #levels > 0 and Depth.BuyCost(levels, reagent.quantity) or false
      cache[key] = purchase
    end
    if not purchase then return nil, "reagent_not_on_ah" end
    if not purchase.complete then return nil, "reagent_depth" end
    cost = cost + purchase.cost
    reagents[#reagents + 1] = { itemID = reagent.itemID, quantity = reagent.quantity, cost = purchase.cost }
  end
  local outputMarket = market(output.itemID)
  local best, exits = Crafting.Exits(outputMarket, output.quantity, settings)
  if not best then
    return nil, (outputMarket and outputMarket.sellPrice == nil) and "output_price_pending" or "output_no_value"
  end
  local profit = best.net - cost
  return {
    strategy = "crafting", recipeID = recipe.id, name = recipe.name, profession = recipe.profession,
    learned = recipe.learned == true, difficulty = recipe.difficulty,
    outputItemID = output.itemID, quantity = output.quantity, quantityMax = recipe.quantityMax,
    cost = cost, reagents = reagents, exit = best.exit, gross = best.gross, fee = best.fee, revenue = best.net,
    profit = profit, roi = cost > 0 and profit / cost or nil, exits = exits,
    -- The merchant price is verified in game; AH exits have no deposit
    -- estimate yet and the "now" price has no history behind it.
    class = best.exit == "vendor" and "prudent" or "speculative",
  }
end

-- All recipes, in steps (one recipe each) so the client can spread them
-- over frames: in game one pass over ~690 recipes took 360-380 ms in a
-- single frame (2026-11-07, build 70862). EvaluateRecipes runs all steps.
-- Result: { learned = rows, learnable = rows, counts, excluded }, rows with
-- a positive profit only, best profit first.
function Crafting.BeginRecipes(recipes, market, settings)
  return {
    recipes = recipes, market = market, settings = settings, cache = {},
    result = { learned = {}, learnable = {}, excluded = {}, counts = { recipes = #recipes, evaluated = 0 } },
  }
end

function Crafting.RecipeStep(job, index)
  local result = job.result
  local row, reason = Crafting.EvaluateRecipe(job.recipes[index], job.market, job.settings, job.cache)
  if row then
    result.counts.evaluated = result.counts.evaluated + 1
    if row.profit > 0 then
      local list = row.learned and result.learned or result.learnable
      list[#list + 1] = row
    else
      result.excluded.no_profit = (result.excluded.no_profit or 0) + 1
    end
  else
    result.excluded[reason] = (result.excluded[reason] or 0) + 1
  end
end

function Crafting.FinishRecipes(job)
  local result = job.result
  local function byProfit(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.recipeID < b.recipeID
  end
  table.sort(result.learned, byProfit)
  table.sort(result.learnable, byProfit)
  return result
end

function Crafting.EvaluateRecipes(recipes, market, settings)
  local job = Crafting.BeginRecipes(recipes, market, settings)
  for index = 1, #recipes do Crafting.RecipeStep(job, index) end
  return Crafting.FinishRecipes(job)
end
