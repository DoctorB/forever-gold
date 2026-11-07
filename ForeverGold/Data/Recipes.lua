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
-- The recipe lists are shared by the account's characters; `owned` is the
-- current character's own record, owned[profession] = { at, skill, maxSkill,
-- learned = { [recipeID] = true } }: only its professions are loaded, with
-- its skill and its learned recipes. Without `owned` (character unknown)
-- every list is loaded with the flags it was saved with.
function Recipes.Load(saved, owned)
  Recipes.Clear()
  for name, entry in pairs(type(saved) == "table" and saved or {}) do
    local mine = type(owned) == "table" and owned[name] or nil
    if type(entry) == "table" and type(entry.list) == "table" and (owned == nil or type(mine) == "table") then
      local source = mine or entry
      Recipes.professions[name] = { at = source.at, skill = source.skill, maxSkill = source.maxSkill, count = #entry.list }
      local learned = mine and type(mine.learned) == "table" and mine.learned or {}
      for _, recipe in ipairs(entry.list) do
        if mine then
          local copy = {}
          for key, value in pairs(recipe) do copy[key] = value end
          copy.learned = learned[recipe.id] == true
          Recipes.Add(copy)
        else
          Recipes.Add(recipe)
        end
      end
      if not Recipes.observedAt or (source.at or 0) > Recipes.observedAt then Recipes.observedAt = source.at end
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
