-- Professions adapter (phase 4). Only presence checks for now: recipe
-- discovery through C_TradeSkillUI needs the profession window and is not
-- verified on this client, so Data/Recipes stays "unavailable".
local _, ns = ...

local Professions = {}
ns.Compat.Professions = Professions

function Professions.New(client)
  return setmetatable({ client = client }, { __index = Professions })
end

function Professions:GetCapabilities()
  local c = self.client
  return {
    recipeInfo = c:Lookup("C_TradeSkillUI", "GetRecipeInfo") ~= nil,
    recipeSchematic = c:Lookup("C_TradeSkillUI", "GetRecipeSchematic") ~= nil,
    observed = false,
  }
end
