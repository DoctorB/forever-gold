-- Recipe registry: filled at runtime from recipes the client exposes for the
-- player's professions (Compat/Professions.lua). No static catalogue is
-- shipped: the addon does not promise recipes it cannot observe.
-- Recipe shape used by Strategies/Crafting and Strategies/Conversion:
--   { id, name, outputs = { { itemID, quantity } }, reagents = { { itemID, quantity } },
--     learned = bool, cooldown = seconds?, requirements = { ... }, verified = bool }
local _, ns = ...

local Recipes = { version = 1, status = "unavailable", byId = {}, observedAt = nil }
ns.Data.Recipes = Recipes

function Recipes.Add(recipe)
  if type(recipe) ~= "table" or recipe.id == nil then return false end
  if type(recipe.outputs) ~= "table" or type(recipe.reagents) ~= "table" then return false end
  Recipes.byId[recipe.id] = recipe
  Recipes.status = "observed"
  return true
end

function Recipes.Clear()
  Recipes.byId = {}
  Recipes.status = "unavailable"
end
