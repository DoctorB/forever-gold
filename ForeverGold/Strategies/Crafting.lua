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
-- The "current lowest" AH price is used only with at least this many
-- listings of the result: in game (2026-11-07) single overpriced weapons and
-- armour made unlearned recipes look worth 100-250 gold.
Crafting.MIN_LISTINGS = 3

-- Listings and units of an item on the AH, computed once per market entry.
function Crafting.Liquidity(market)
  if not market then return 0, 0, nil end
  if market.book == nil then
    local book = Depth.Book(market.levels or {})
    local units = 0
    for _, level in ipairs(book) do units = units + level.quantity end
    market.book, market.units = book, units
  end
  local first = market.book[1]
  local lowest = first and (first.divisible and first.unitPrice or Money.DivCeil(first.buyoutTotal, first.quantity))
  return #market.book, market.units, lowest
end

-- Without price history, the AH is assumed to take at most this share of
-- the units already listed (at least one): a guess, labelled speculative.
Crafting.AH_NOW_SHARE_BP = 500

-- Units the AH cannot take go to a merchant when the item has a merchant
-- price; otherwise they stay unsold (no revenue counted).
local function withRest(exit, sold, quantity, sellPrice)
  local rest = quantity - sold
  exit.sold, exit.unsold, exit.vendorUnits = sold, 0, 0
  if rest > 0 then
    if Money.IsCopper(sellPrice) and sellPrice > 0 then
      local extra = Money.Mul(sellPrice, rest)
      exit.gross, exit.net, exit.vendorUnits = exit.gross + extra, exit.net + extra, rest
    else
      exit.unsold = rest
    end
  end
  return exit
end

-- Expected deposit loss of an AH sale (Economy/Deposit), 0 when the
-- deposit is unknown (no merchant price): the row then says so.
local function depositLoss(market, units, settings)
  local deposit = market and market.depositFor and market.depositFor(units)
  if not deposit then return 0 end
  return ns.Economy.Deposit.ExpectedLoss(deposit, settings.depositLossBp or ns.Strategies.Resale.DEFAULT_DEPOSIT_LOSS_BP) or 0
end

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
  local _, _, competitor = Crafting.Liquidity(market)
  local resale = market and market.estimate and MarketValue.PrudentResale({
    estimate = market.estimate, competitor = competitor, units = quantity, bufferBp = settings.bufferBp,
  })
  if resale then
    local net, fee = Costs.NetRevenue(resale.prudentGross, feeBp)
    net = net and net - depositLoss(market, resale.sellUnits, settings)
    if net and net > 0 then
      exits[#exits + 1] = withRest({ exit = "ah", gross = resale.prudentGross, net = net, fee = fee,
        deposit = market.depositFor and market.depositFor(resale.sellUnits) }, resale.sellUnits, quantity, sellPrice)
    end
  else
    local listings, units, lowest = Crafting.Liquidity(market)
    if lowest and listings >= Crafting.MIN_LISTINGS then
      local unit = lowest - Money.ShareUp(lowest, settings.bufferBp or 0)
      local cap = math.max(1, math.floor(units * Crafting.AH_NOW_SHARE_BP / Money.BP))
      local sold = math.min(quantity, cap)
      local gross = Money.Mul(unit, sold)
      local net, fee = Costs.NetRevenue(gross, feeBp)
      net = net and net - depositLoss(market, sold, settings)
      if net and net > 0 then
        exits[#exits + 1] = withRest({ exit = "ah_now", gross = gross, net = net, fee = fee,
          deposit = market.depositFor and market.depositFor(sold) }, sold, quantity, sellPrice)
      end
    end
  end
  table.sort(exits, function(a, b) return a.net > b.net end)
  return exits[1], exits
end

-- One recipe, one craft: reagents bought on the AH at their real depth, the
-- output sold at its best exit. market(itemID) -> { levels, sellPrice?, estimate? } or nil;
-- cache: per-run table shared by all recipes (reagent costs by item and quantity).
-- Returns a row, or nil, reason.
-- Reagents the player can make: a reagent with no price (not on the AH,
-- no merchant seen) or too few units is costed by the cheapest recipe of
-- the catalogue that produces it, down to MAX_CHAIN levels. In game
-- (2026-11-07) Solid Grinding Stone alone blocked 20 recipes, and it is made
-- from Solid Stone.
Crafting.MAX_CHAIN = 3

-- Recipes by the item they produce.
function Crafting.Producers(recipes)
  local producers = {}
  for _, recipe in ipairs(recipes or {}) do
    local output = recipe.outputs and recipe.outputs[1]
    if output and Money.IsQuantity(output.quantity) then
      local list = producers[output.itemID] or {}
      producers[output.itemID] = list
      list[#list + 1] = recipe
    end
  end
  return producers
end

local acquire

-- Cheapest way to make `quantity` units with a producing recipe, or nil.
-- Returns { cost, crafts, recipe, learned (whole chain), alsoLearn = { names } }.
local function craftCost(itemID, quantity, ctx, depth, visiting)
  local list = ctx.producers and ctx.producers[itemID]
  if not list or depth >= Crafting.MAX_CHAIN then return nil end
  visiting[itemID] = true
  local best
  for _, producer in ipairs(list) do
    local per = producer.outputs[1].quantity
    local crafts = math.ceil(quantity / per)
    local cost, learned, alsoLearn, ok = 0, producer.learned == true, {}, true
    if not learned then alsoLearn[#alsoLearn + 1] = producer.name or ("#" .. tostring(producer.id)) end
    for _, reagent in ipairs(producer.reagents or {}) do
      local part = (not visiting[reagent.itemID]) and acquire(reagent.itemID, reagent.quantity * crafts, ctx, depth + 1, visiting)
      if not part then
        ok = false
        break
      end
      cost = cost + part.cost
      if part.crafted then
        learned = learned and part.crafted.learned
        for _, name in ipairs(part.crafted.alsoLearn) do alsoLearn[#alsoLearn + 1] = name end
      end
    end
    -- Prefer recipes already known, then the cheaper one.
    if ok and (not best or (learned and not best.learned) or (learned == best.learned and cost < best.cost)) then
      best = { cost = cost, crafts = crafts, recipe = producer, learned = learned, alsoLearn = alsoLearn }
    end
  end
  visiting[itemID] = nil
  return best
end

-- Cost of `quantity` units: AH and merchant first, otherwise made by the
-- player. Returns { cost, merchant, crafted? } or nil, reason.
acquire = function(itemID, quantity, ctx, depth, visiting)
  local key = itemID .. "x" .. quantity
  local cached = ctx.buys[key]
  if cached ~= nil and depth == 0 then
    if cached then return cached end
    return nil, ctx.reasons[key]
  end
  local entry = ctx.market(itemID)
  local levels = entry and (entry.reagentLevels or entry.levels)
  local purchase
  if levels and #levels > 0 then
    -- Sorted once per item and run: several quantities are priced per recipe.
    entry.reagentBook = entry.reagentBook or Depth.Book(levels)
    purchase = Depth.BuyCostSorted(entry.reagentBook, quantity)
  end
  local result, reason
  if purchase and purchase.complete then
    local merchant = false
    for _, use in ipairs(purchase.used) do if use.level and use.level.merchant then merchant = true end end
    result = { cost = purchase.cost, merchant = merchant }
  else
    reason = purchase and "reagent_depth" or "reagent_not_on_ah"
    local made = craftCost(itemID, quantity, ctx, depth, visiting)
    if made then result = { cost = made.cost, merchant = false, crafted = made } end
  end
  if depth == 0 then
    ctx.buys[key] = result or false
    ctx.reasons[key] = reason
  end
  return result, reason
end

-- Context shared by all recipes of one run (caches and producers).
function Crafting.Context(recipes, market, ownedCount)
  return { buys = {}, reasons = {}, market = market, producers = Crafting.Producers(recipes), ownedCount = ownedCount }
end

-- Several crafts: the reagents are bought deeper into the AH book (dearer
-- lots, possibly running out) and the AH takes only so many results (the
-- rest goes to a merchant or stays unsold). Every count from 1 to
-- MAX_CRAFTS is priced and the one with the largest total gain is kept,
-- with what stopped it: "reagents" (not enough on sale), "demand" (the AH
-- would not take more), "price" (dearer reagents) or "max".
Crafting.MAX_CRAFTS = 20

function Crafting.BestRun(recipe, output, outputMarket, settings, ctx, first)
  local best, limit = first, nil
  for crafts = 2, Crafting.MAX_CRAFTS do
    local cost, ok = 0, true
    for _, reagent in ipairs(recipe.reagents or {}) do
      local part = acquire(reagent.itemID, reagent.quantity * crafts, ctx, 0, { [output.itemID] = true })
      if not part then
        ok = false
        break
      end
      cost = cost + part.cost
    end
    if not ok then
      limit = limit or "reagents"
      break
    end
    local exit = Crafting.Exits(outputMarket, output.quantity * crafts, settings)
    if not exit then break end
    local profit = exit.net - cost
    if profit > best.profit then
      best = { crafts = crafts, cost = cost, revenue = exit.net, profit = profit, exit = exit.exit, sold = exit.sold,
        vendorUnits = exit.vendorUnits, unsold = exit.unsold }
      limit = nil
    elseif not limit then
      limit = ((exit.unsold or 0) > 0 or (exit.vendorUnits or 0) > 0) and "demand" or "price"
    end
  end
  best.limit = limit or (best.crafts == Crafting.MAX_CRAFTS and "max" or "price")
  return best
end

-- Reagents already in the bags (spec 9.4): they are not free, so the gain
-- stays computed at market prices, but the money to spend now only covers
-- what is missing. Fills run.spend (gold to spend), run.ownedValue (market
-- value of the reagents used from the bags) and run.owned[itemID] = units.
function Crafting.Spend(recipe, output, run, ctx)
  run.spend, run.ownedValue, run.owned = run.cost, 0, nil
  if not ctx.ownedCount then return run end
  local spend = 0
  for _, reagent in ipairs(recipe.reagents or {}) do
    local need = reagent.quantity * run.crafts
    local have = math.min(ctx.ownedCount(reagent.itemID) or 0, need)
    local full = acquire(reagent.itemID, need, ctx, 0, { [output.itemID] = true })
    if not full then return run end
    if have > 0 then
      run.owned = run.owned or {}
      run.owned[reagent.itemID] = have
      local rest = need - have
      local part = rest > 0 and acquire(reagent.itemID, rest, ctx, 0, { [output.itemID] = true }) or { cost = 0 }
      if not part then return run end
      spend = spend + part.cost
    else
      spend = spend + full.cost
    end
  end
  run.spend, run.ownedValue = spend, run.cost - spend
  return run
end

function Crafting.EvaluateRecipe(recipe, market, settings, ctx)
  local output = recipe.outputs and recipe.outputs[1]
  if not output or not Money.IsQuantity(output.quantity) then return nil, "output_unknown" end
  ctx = ctx or Crafting.Context(nil, market)
  ctx.buys, ctx.reasons, ctx.market = ctx.buys or {}, ctx.reasons or {}, ctx.market or market
  local cost, reagents, learned, alsoLearn = 0, {}, recipe.learned == true, {}
  for _, reagent in ipairs(recipe.reagents or {}) do
    local part, reason = acquire(reagent.itemID, reagent.quantity, ctx, 0, { [output.itemID] = true })
    if not part then return nil, reason end
    cost = cost + part.cost
    local crafted = part.crafted
    if crafted then
      learned = learned and crafted.learned
      for _, name in ipairs(crafted.alsoLearn) do alsoLearn[#alsoLearn + 1] = name end
    end
    reagents[#reagents + 1] = { itemID = reagent.itemID, quantity = reagent.quantity, cost = part.cost,
      merchant = part.merchant,
      crafted = crafted and { recipeID = crafted.recipe.id, name = crafted.recipe.name, crafts = crafted.crafts,
        learned = crafted.learned } or nil }
  end
  local outputMarket = market(output.itemID)
  local best, exits = Crafting.Exits(outputMarket, output.quantity, settings)
  local listings, units = Crafting.Liquidity(outputMarket)
  if not best then
    if outputMarket and outputMarket.sellPrice == nil then return nil, "output_price_pending" end
    if listings > 0 and listings < Crafting.MIN_LISTINGS then return nil, "thin_market" end
    return nil, "output_no_value"
  end
  local profit = best.net - cost
  local run = Crafting.BestRun(recipe, output, outputMarket, settings, ctx,
    { crafts = 1, cost = cost, revenue = best.net, profit = profit, exit = best.exit, sold = best.sold,
      vendorUnits = best.vendorUnits, unsold = best.unsold })
  Crafting.Spend(recipe, output, run, ctx)
  return {
    run = run,
    strategy = "crafting", recipeID = recipe.id, name = recipe.name, profession = recipe.profession,
    -- Known only when every recipe of the chain is known; otherwise the
    -- recipes still to learn are listed (alsoLearn, besides this one).
    learned = learned, alsoLearn = #alsoLearn > 0 and alsoLearn or nil, difficulty = recipe.difficulty,
    outputItemID = output.itemID, quantity = output.quantity, quantityMax = recipe.quantityMax,
    cost = cost, reagents = reagents, exit = best.exit, gross = best.gross, fee = best.fee, revenue = best.net,
    profit = profit, roi = cost > 0 and profit / cost or nil, exits = exits,
    listings = listings, units = units, -- the result already on the AH (competition)
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
-- A recipe still to learn and its skill requirement, for the character's
-- skill: { skill, exact = true, cost } when a trainer gave it, else
-- { trivial } (the grey level, an upper bound); `later` when it needs more
-- skill than the character has. Recipes turn grey 20-75 points above the
-- skill they require in the data seen (e.g. Smelt Copper 1 -> 70, Smelt
-- Thorium 230 -> 250): REACH_SPAN keeps a margin before calling it later.
Crafting.REACH_SPAN = 100

function Crafting.Reach(recipe, skill)
  if recipe.learned then return nil end
  local known = type(skill) == "number"
  if type(recipe.requiredSkill) == "number" then
    return { skill = recipe.requiredSkill, exact = true, cost = recipe.learnCost,
      later = known and skill < recipe.requiredSkill }
  end
  if type(recipe.trivial) == "number" then
    return { trivial = recipe.trivial, later = known and skill + Crafting.REACH_SPAN < recipe.trivial }
  end
  return nil
end

-- skills: { [profession] = current skill } of the character (optional).
function Crafting.BeginRecipes(recipes, market, settings, ownedCount, skills)
  return {
    skills = skills or {},
    recipes = recipes, market = market, settings = settings, cache = Crafting.Context(recipes, market, ownedCount),
    result = { learned = {}, learnable = {}, excluded = {}, counts = { recipes = #recipes, evaluated = 0 } },
  }
end

function Crafting.RecipeStep(job, index)
  local result = job.result
  local recipe = job.recipes[index]
  local reach = Crafting.Reach(recipe, job.skills[recipe.profession])
  if reach and reach.later then
    -- Needs more skill than the character has: not a choice for now.
    result.excluded.skill = (result.excluded.skill or 0) + 1
    return
  end
  local row, reason = Crafting.EvaluateRecipe(recipe, job.market, job.settings, job.cache)
  if row then
    row.requires = reach
    result.counts.evaluated = result.counts.evaluated + 1
    if row.run.profit > 0 then
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
  -- Best total gain first (several crafts), then the gain of one craft.
  local function byProfit(a, b)
    if a.run.profit ~= b.run.profit then return a.run.profit > b.run.profit end
    if a.profit ~= b.profit then return a.profit > b.profit end
    return a.recipeID < b.recipeID
  end
  table.sort(result.learned, byProfit)
  table.sort(result.learnable, byProfit)
  return result
end

function Crafting.EvaluateRecipes(recipes, market, settings, ownedCount, skills)
  local job = Crafting.BeginRecipes(recipes, market, settings, ownedCount, skills)
  for index = 1, #recipes do Crafting.RecipeStep(job, index) end
  return Crafting.FinishRecipes(job)
end
