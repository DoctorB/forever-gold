-- Capabilities: what this client is known to support, and how we know.
-- Statuses (spec 3): documented, present, runtime_verified, unsupported, unknown.
-- Player-visible behaviour depends only on VERIFIED, kept in sync with the
-- marker comment in docs/API-AUDIT.md (checked by tests/test_capabilities.lua).
local _, ns = ...

local Capabilities = {}
ns.Core.Capabilities = Capabilities

Capabilities.STATUSES = {
  documented = 1, present = 2, runtime_verified = 3, unsupported = 4, unknown = 5,
}

-- Semantics proven in game. Each flag moves to true only together with the
-- evidence recorded in docs/API-AUDIT.md.
Capabilities.VERIFIED = {
  replicate = false, -- ReplicateItems delivers the AH and we read it fully
  replicateBuyoutIsTotal = true, -- 2026-10-20, build 70450: 8/8 samples exact multiples of count, unit prices match the AH browse view
  replicateIndexBase = true, -- 2026-10-20, build 70450: 0-based, 31,058 rows read with no discard
  commoditySearch = false,
  itemSearch = false,
  itemSearchBuyoutIsTotal = false, -- buyoutAmount of a multi-unit item auction
  sellPrice = false, -- C_Item.GetItemInfo sellPrice matches the vendor
  persistence = true, -- 2026-10-20, build 70450: re-read after /reload, relog and restart
  fee = false, -- AH cut measured on a real sale
  deposit = false,
}

function Capabilities.New()
  return setmetatable({ entries = {}, order = {} }, { __index = Capabilities })
end

-- Records or updates one capability.
function Capabilities:Set(id, status, detail)
  if not Capabilities.STATUSES[status] then status = "unknown" end
  local entry = self.entries[id]
  if not entry then
    entry = { id = id }
    self.entries[id] = entry
    self.order[#self.order + 1] = id
  end
  entry.status = status
  entry.detail = detail
  return entry
end

function Capabilities:Get(id)
  local entry = self.entries[id]
  return entry and entry.status or "unknown", entry and entry.detail
end

-- True when the symbol exists on this client (present or better).
function Capabilities:Has(id)
  local status = self:Get(id)
  return status == "present" or status == "runtime_verified"
end

function Capabilities:List()
  local list = {}
  for _, id in ipairs(self.order) do list[#list + 1] = self.entries[id] end
  return list
end

-- Evidence gathered by the addon itself on this client (for example the
-- vendor check after a real sale). Persisted in ForeverGoldDB.verifiedRuntime
-- by Core/App; a flag counts as verified with either kind of evidence.
Capabilities.runtime = {}

function Capabilities.IsVerified(flag)
  return Capabilities.VERIFIED[flag] == true or Capabilities.runtime[flag] ~= nil
end

function Capabilities.RecordRuntime(flag, evidence)
  Capabilities.runtime[flag] = evidence
end
