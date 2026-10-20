-- Disenchant dataset: outcome baskets per item class, versioned per ruleset.
-- EMPTY on purpose: no Forever-verified probabilities exist yet, and Retail
-- or Vanilla tables are not imported as facts. With no dataset the DE
-- ranking stays disabled; only a labelled manual scenario is possible.
local _, ns = ...

ns.Data.Disenchant = {
  version = 0,
  ruleset = nil, -- e.g. "forever-1.60.1" once measured
  source = nil, -- origin, licence and sample size are required with data
  license = nil,
  sampleSize = 0,
  status = "unavailable",
  -- entries[key] = { requirements = {...}, outcomes = { { p = 0.5, basket = { [itemID] = qty } } } }
  entries = {},
}
