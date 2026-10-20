-- Diagnostics: non-destructive capability report for /fg diagnostics.
-- Presence checks and plain getters only: nothing is bought, posted,
-- crafted or cancelled to "test" a function. The report and a bounded event
-- trace are saved in ForeverGoldDB.diagnostics for docs/API-AUDIT.md.
-- No seller names, chat text or GUIDs are recorded.
local _, ns = ...

local Capabilities = ns.Core.Capabilities
local Diagnostics = {}
ns.Services.Diagnostics = Diagnostics

Diagnostics.TRACE_LIMIT = 200
Diagnostics.SAMPLE_LIMIT = 8

-- deps: { client, capabilities, store, clock, events = { registered, rejected } }
function Diagnostics.New(deps)
  local self = setmetatable(deps, { __index = Diagnostics })
  local diag = self.store.db.diagnostics
  diag.trace = diag.trace or {}
  return self
end

-- Bounded ring of scanner and client events, with timestamps.
function Diagnostics:Trace(kind, data)
  local trace = self.store.db.diagnostics.trace
  local entry = { t = self.clock(), k = kind }
  if type(data) == "table" then
    for key, value in pairs(data) do
      local valueType = type(value)
      if valueType == "number" or valueType == "boolean" or (valueType == "string" and #value <= 64) then
        entry[key] = value
      end
    end
  end
  trace[#trace + 1] = entry
  while #trace > Diagnostics.TRACE_LIMIT do table.remove(trace, 1) end
end

function Diagnostics:Run()
  local client, capabilities = self.client, self.capabilities
  client:Detect(capabilities)
  local db = self.store.db
  local report = {
    at = self.clock(),
    addonVersion = ns.VERSION,
    build = client:BuildInfo(),
    market = client:MarketFields(),
    symbols = {},
    events = self.events,
    verified = {},
    persistence = {
      loads = db.meta.loads, created = db.meta.created, lastLoad = db.meta.lastLoad,
      previousLoad = db.meta.previousLoad, sessionOnly = self.store.sessionOnly,
      schema = db.schema, migration = self.store.report,
    },
  }
  for _, entry in ipairs(capabilities:List()) do
    report.symbols[entry.id] = entry.status
  end
  for flag, value in pairs(Capabilities.VERIFIED) do report.verified[flag] = value end
  local okCopper, copper = client:Call("C_AuctionHouse", "SupportsCopperValues")
  if okCopper then report.supportsCopperValues = copper end
  db.diagnostics.report = report
  return report
end

-- Records a few multi-unit replicate rows (item id, count, buyout, bid) so
-- the user can compare them with the native AH window and settle whether
-- buyoutPrice is a stack total. Returns the number of samples.
function Diagnostics:SampleListings(latest)
  local samples = {}
  for itemKey, view in pairs(latest or {}) do
    for _, listing in ipairs(view.listings) do
      if #samples >= Diagnostics.SAMPLE_LIMIT then break end
      if listing.source == "replicate" and listing.quantity > 1 and listing.buyoutTotal then
        samples[#samples + 1] = {
          itemKey = itemKey, quantity = listing.quantity, buyout = listing.buyoutTotal, bid = listing.bid,
        }
      end
    end
  end
  self.store.db.diagnostics.samples = samples
  return #samples
end

-- Summary lines for chat output.
function Diagnostics.Summary(report, L)
  local lines = {}
  local build = report.build or {}
  lines[#lines + 1] = string.format(L["DIAG_BUILD"], tostring(build.version), tostring(build.build),
    tostring(build.interface), tostring(build.projectID))
  local present, missing = 0, {}
  for id, status in pairs(report.symbols) do
    if status == "present" or status == "runtime_verified" then
      present = present + 1
    else
      missing[#missing + 1] = id
    end
  end
  table.sort(missing)
  lines[#lines + 1] = string.format(L["DIAG_SYMBOLS"], present, present + #missing)
  if #missing > 0 then lines[#lines + 1] = L["DIAG_MISSING"] .. " " .. table.concat(missing, ", ") end
  local events = report.events or {}
  lines[#lines + 1] = string.format(L["DIAG_EVENTS"], #(events.registered or {}), #(events.rejected or {}))
  if events.rejected and #events.rejected > 0 then
    lines[#lines + 1] = L["DIAG_REJECTED"] .. " " .. table.concat(events.rejected, ", ")
  end
  local p = report.persistence
  lines[#lines + 1] = string.format(L["DIAG_PERSIST"], p.loads or 0, p.sessionOnly and L["YES"] or L["NO"])
  local verified = 0
  for _, value in pairs(report.verified) do if value then verified = verified + 1 end end
  lines[#lines + 1] = string.format(L["DIAG_VERIFIED"], verified)
  return lines
end
