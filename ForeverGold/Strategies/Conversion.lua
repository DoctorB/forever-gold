-- Conversion arbitrage: chains of recipes on a simulated resource ledger
-- (spec 9.5), phase 5. Bounded depth (3 steps by default), finite stock,
-- cycles blocked during the search, equivalent paths deduplicated.
local _, ns = ...

local Depth = ns.Economy.Depth
local Conversion = { id = "conversion", MAX_STEPS = 3, MAX_NODES = 2000 }
ns.Strategies.Conversion = Conversion

local function copyInventory(inventory)
  local copy = {}
  for itemID, quantity in pairs(inventory) do copy[itemID] = quantity end
  return copy
end

-- Whole crafts the inventory allows for a recipe (0 when any reagent lacks).
local function maxCrafts(recipe, inventory)
  local crafts
  for _, reagent in ipairs(recipe.reagents) do
    local possible = math.floor((inventory[reagent.itemID] or 0) / reagent.quantity)
    if not crafts or possible < crafts then crafts = possible end
  end
  return crafts or 0
end

-- Applies `crafts` crafts: consumes reagents, adds outputs. Returns a new
-- inventory; the old one is untouched.
function Conversion.Apply(recipe, inventory, crafts)
  local result = copyInventory(inventory)
  for _, reagent in ipairs(recipe.reagents) do
    local left = (result[reagent.itemID] or 0) - reagent.quantity * crafts
    if left < 0 then return nil, "insufficient" end
    result[reagent.itemID] = left > 0 and left or nil
  end
  for _, output in ipairs(recipe.outputs) do
    result[output.itemID] = (result[output.itemID] or 0) + output.quantity * crafts
  end
  return result
end

-- Value of an inventory at prudent unit prices; unknown prices count zero
-- and are reported.
local function valueOf(inventory, market)
  local value, unknown = 0, {}
  for itemID, quantity in pairs(inventory) do
    local price = market[itemID] and market[itemID].sellPrice
    if type(price) == "number" then
      value = value + price * quantity
    else
      unknown[#unknown + 1] = itemID
    end
  end
  return value, unknown
end

-- Plans from buying `units` of startItemID.
-- Returns { best = { path, inventory, value, profit, unknown }, explored,
--   cyclesBlocked, purchase } or nil, reason.
function Conversion.Plan(startItemID, units, recipes, market, maxSteps)
  maxSteps = math.min(maxSteps or Conversion.MAX_STEPS, Conversion.MAX_STEPS)
  local start = market[startItemID]
  local purchase = Depth.BuyCost(start and start.levels or {}, units)
  if not purchase or not purchase.complete then return nil, "start_depth" end
  local result = { explored = 0, cyclesBlocked = 0, purchase = purchase, best = nil }
  local seenPaths = {}

  local function consider(path, inventory)
    local value, unknown = valueOf(inventory, market)
    local profit = value - purchase.cost
    if #path > 0 and #unknown == 0 and (not result.best or profit > result.best.profit) then
      result.best = { path = path, inventory = inventory, value = value, profit = profit, unknown = unknown }
    end
  end

  local function search(path, inventory, visited)
    result.explored = result.explored + 1
    if result.explored > Conversion.MAX_NODES then return end
    consider(path, inventory)
    if #path >= maxSteps then return end
    for _, recipe in ipairs(recipes) do
      local crafts = maxCrafts(recipe, inventory)
      if crafts > 0 then
        local cycle = false
        for _, output in ipairs(recipe.outputs) do
          if visited[output.itemID] then cycle = true end
        end
        if cycle then
          result.cyclesBlocked = result.cyclesBlocked + 1
        else
          local nextPath = {}
          for index = 1, #path do nextPath[index] = path[index] end
          nextPath[#nextPath + 1] = { recipe = recipe.id, crafts = crafts }
          local keyParts = {}
          for index, step in ipairs(nextPath) do keyParts[index] = tostring(step.recipe) .. "x" .. step.crafts end
          local key = table.concat(keyParts, ">")
          if not seenPaths[key] then
            seenPaths[key] = true
            local nextInventory = Conversion.Apply(recipe, inventory, crafts)
            local nextVisited = copyInventory(visited)
            for _, output in ipairs(recipe.outputs) do nextVisited[output.itemID] = true end
            search(nextPath, nextInventory, nextVisited)
          end
        end
      end
    end
  end

  search({}, { [startItemID] = purchase.quantity }, { [startItemID] = true })
  return result
end

function Conversion.Evaluate(context)
  local recipes = context.recipes or ns.Data.Recipes
  if not recipes or recipes.status ~= "observed" then
    return {}, { recipes_unavailable = 1 }
  end
  return {}, { not_implemented = 1 }
end
