-- Disenchant: buy and disenchant (spec 9.3), phase 4.
--   EVoutput = sum_j(p_j * netBasketValue_j)
-- Each outcome is a complete basket, so mutually exclusive materials are not
-- double counted. Ranking stays disabled while ns.Data.Disenchant has no
-- verified dataset; the pure functions serve labelled manual scenarios.
local _, ns = ...

local Disenchant = { id = "disenchant", MAX_ITEMS = 50, MAX_STATES = 10000 }
ns.Strategies.Disenchant = Disenchant

local function validOutcomes(outcomes)
  if type(outcomes) ~= "table" or #outcomes == 0 then return false end
  local total = 0
  for _, outcome in ipairs(outcomes) do
    if type(outcome.p) ~= "number" or outcome.p < 0 or type(outcome.value) ~= "number" then return false end
    total = total + outcome.p
  end
  return math.abs(total - 1) < 1e-9
end

-- Expected net output value of one disenchant.
function Disenchant.ExpectedValue(outcomes)
  if not validOutcomes(outcomes) then return nil, "invalid_outcomes" end
  local ev = 0
  for _, outcome in ipairs(outcomes) do ev = ev + outcome.p * outcome.value end
  return ev
end

-- Distribution of the summed output of n independent disenchants.
-- Returns map value -> probability, or nil, reason when too large.
function Disenchant.Distribution(outcomes, n)
  if not validOutcomes(outcomes) then return nil, "invalid_outcomes" end
  if n < 1 or n > Disenchant.MAX_ITEMS then return nil, "too_many_items" end
  local states = { [0] = 1 }
  for _ = 1, n do
    local nextStates, size = {}, 0
    for value, p in pairs(states) do
      for _, outcome in ipairs(outcomes) do
        local sum = value + outcome.value
        if nextStates[sum] == nil then size = size + 1 end
        nextStates[sum] = (nextStates[sum] or 0) + p * outcome.p
      end
    end
    if size > Disenchant.MAX_STATES then return nil, "too_many_states" end
    states = nextStates
  end
  return states
end

-- Scenario for n items each bought at unitCost (purchase counted once).
-- Returns { evProfit, lossProbability, worst, best }.
function Disenchant.Scenario(outcomes, unitCost, n)
  local ev, reason = Disenchant.ExpectedValue(outcomes)
  if not ev then return nil, reason end
  local distribution, why = Disenchant.Distribution(outcomes, n)
  if not distribution then return nil, why end
  local cost = unitCost * n
  local loss, worst, best = 0, nil, nil
  for value, p in pairs(distribution) do
    if value < cost then loss = loss + p end
    if not worst or value < worst then worst = value end
    if not best or value > best then best = value end
  end
  return {
    evProfit = ev * n - cost,
    lossProbability = loss,
    worst = worst - cost,
    best = best - cost,
  }
end

function Disenchant.Evaluate(context)
  local dataset = context.disenchant or ns.Data.Disenchant
  if not dataset or dataset.status ~= "verified" then
    return {}, { dataset_unavailable = 1 }
  end
  -- Ranking is enabled only with a verified dataset (phase 4 gate).
  return {}, { not_implemented = 1 }
end
