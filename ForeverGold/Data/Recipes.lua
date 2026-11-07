-- Recipe registry: filled from the recipes the client exposes for the
-- player's professions (Compat/Professions.lua, observed when a profession
-- window opens) and kept in ForeverGoldDB.recipes[profession]. No static
-- catalogue is shipped: the addon does not promise recipes it cannot observe.
-- Recipe shape used by Strategies/Crafting and Strategies/Conversion:
--   { id, name, profession, outputs = { { itemID, quantity } }, quantityMax?,
--     reagents = { { itemID, quantity } }, learned = bool, difficulty? }
local _, ns = ...

local Recipes = { version = 1, status = "unavailable", byId = {}, observedAt = nil, professions = {} }
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
  Recipes.professions = {}
  Recipes.status = "unavailable"
end

-- Rebuilds the registry from the saved observations:
-- saved[profession] = { at, build, skill, maxSkill, list = { recipe, ... } }.
function Recipes.Load(saved)
  Recipes.Clear()
  for name, entry in pairs(type(saved) == "table" and saved or {}) do
    if type(entry) == "table" and type(entry.list) == "table" then
      Recipes.professions[name] = { at = entry.at, skill = entry.skill, maxSkill = entry.maxSkill, count = #entry.list }
      for _, recipe in ipairs(entry.list) do Recipes.Add(recipe) end
      if not Recipes.observedAt or (entry.at or 0) > Recipes.observedAt then Recipes.observedAt = entry.at end
    end
  end
  return Recipes.status == "observed"
end

-- Recipes as a list sorted by id (deterministic evaluation order).
function Recipes.List()
  local list = {}
  for _, recipe in pairs(Recipes.byId) do list[#list + 1] = recipe end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end
