-- Risk: hard gates and a labelled heuristic confidence score.
-- The score is NOT a probability of profit; it summarises data quality,
-- market risk and feasibility with the reasons kept visible (spec 10).
local _, ns = ...

local Risk = {}
ns.Economy.Risk = Risk

Risk.GATES = {
  "priceValid", "marketKnown", "variantKnown", "quantityAvailable", "requirementsMet", "operationAllowed",
}

-- checks: table gate -> true/false/nil. nil counts as failed (unknown).
function Risk.Gates(checks, extra)
  local failed = {}
  for _, gate in ipairs(Risk.GATES) do
    if checks[gate] ~= true then failed[#failed + 1] = gate end
  end
  for _, gate in ipairs(extra or {}) do
    if checks[gate] ~= true then failed[#failed + 1] = gate end
  end
  return #failed == 0, failed
end

-- Penalties in points; values are initial project choices, tune with data.
Risk.PENALTIES = {
  stale = 25, -- data older than staleSeconds
  partial = 15, -- observation incomplete for the declared scope
  fewSamples = 25, -- fewer independent days than wanted
  dispersion = 15, -- reference window too dispersed
  feeScenario = 15, -- fee is a declared scenario, not verified
  depositUnknown = 10,
  semanticsUnverified = 20, -- client field meaning not verified in game
  thinOutput = 10, -- little listed depth for the output
  capitalHeavy = 10, -- large share of budget on one line
}

Risk.STALE_SECONDS = 2 * 3600
Risk.WANTED_SAMPLES = 7
Risk.MAX_DISPERSION_BP = 4000

-- f: { ageSeconds, partial, samples, dispersionBp, feeVerified, depositKnown,
--      semanticsVerified, depth, capitalBp }
function Risk.Confidence(f)
  local score, reasons = 100, {}
  local function penalise(key, condition)
    if condition then
      score = score - Risk.PENALTIES[key]
      reasons[#reasons + 1] = key
    end
  end
  penalise("stale", f.ageSeconds == nil or f.ageSeconds > Risk.STALE_SECONDS)
  penalise("partial", f.partial ~= false)
  if f.samples ~= nil then
    penalise("fewSamples", f.samples < Risk.WANTED_SAMPLES)
  end
  if f.dispersionBp ~= nil then
    penalise("dispersion", f.dispersionBp > Risk.MAX_DISPERSION_BP)
  end
  if f.feeVerified ~= nil then penalise("feeScenario", not f.feeVerified) end
  if f.depositKnown ~= nil then penalise("depositUnknown", not f.depositKnown) end
  penalise("semanticsUnverified", f.semanticsVerified ~= true)
  if f.depth ~= nil then penalise("thinOutput", f.depth < 5) end
  if f.capitalBp ~= nil then penalise("capitalHeavy", f.capitalBp > 1000) end
  if score < 0 then score = 0 end
  local label = "low"
  if score >= 70 then label = "high" elseif score >= 40 then label = "medium" end
  return { score = score, label = label, reasons = reasons }
end

-- Ranking classes (lower ranks first): confirmed vendor margin, prudent
-- positive profit with good evidence, speculative.
Risk.CLASS_ORDER = { vendor_confirmed = 1, prudent = 2, speculative = 3 }
