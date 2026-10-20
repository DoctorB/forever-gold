-- Store: owns the SavedVariables table after ADDON_LOADED.
-- Persistence is a claim to prove on the real build: until the client has
-- been seen re-reading our data, the UI calls it "not yet verified"; in
-- session mode nothing is written back at all.
local _, ns = ...

local Migrations = ns.Data.Migrations
local Store = {}
ns.Data.Store = Store

Store.DEFAULT_SETTINGS = {
  budget = nil, -- copper chosen by the user; nil = not set, no allocation
  reserveBp = 2000, -- liquid reserve kept out of the budget
  maxItemBp = 1000, -- at most 10% of the budget on one item
  maxCategoryBp = 2500, -- at most 25% on one category
  minRoiBp = 1500, -- resale filter: 15% ROI (product choice, configurable)
  minProfit = 1000, -- resale filter: 10 silver net (product choice)
  minVendorProfit = 1, -- vendor filter in copper
  feeBp = 500, -- AH sale fee SCENARIO until verified in game
  feeVerified = false,
  bufferBp = 500, -- prudent resale buffer
  frameBudgetMs = 2, -- scanner work per frame, to be measured on the client
  notify = true,
  notifyCooldown = 300,
  sessionOnly = false,
}

Store.RETENTION = {
  recentDays = 7, -- detailed observations
  dailyDays = 90, -- daily aggregates
  maxKeys = 10000, -- item keys per market
  budgetBytes = 20 * 1024 * 1024, -- estimated serialized size
}

local function fillDefaults(target, defaults)
  for key, value in pairs(defaults) do
    if target[key] == nil then target[key] = value end
  end
end

-- saved: the SavedVariables table (may be nil on first run).
-- Returns the store object; store.db is the table to write back.
function Store.New(saved, opts)
  opts = opts or {}
  local db, report = Migrations.Run(saved, ns.CopyTable)
  local store = setmetatable({ db = db, report = report }, { __index = Store })
  db.settings = db.settings or {}
  fillDefaults(db.settings, Store.DEFAULT_SETTINGS)
  db.markets = db.markets or {}
  db.ledger = db.ledger or {}
  db.diagnostics = db.diagnostics or {}
  db.meta = db.meta or {}
  db.meta.loads = (db.meta.loads or 0) + 1
  if opts.now then
    -- A previous load time proves the client handed our data back.
    db.meta.previousLoad = db.meta.lastLoad
    db.meta.created = db.meta.created or opts.now
    db.meta.lastLoad = opts.now
  end
  store.sessionOnly = report.readOnly or db.settings.sessionOnly == true
  return store
end

-- Table to hand back to the client's SavedVariables global. In session mode
-- the original content is returned untouched.
function Store:Persisted(original)
  if self.sessionOnly then return original end
  return self.db
end

function Store:Settings()
  return self.db.settings
end

function Store:Market(marketKey, create)
  local market = self.db.markets[marketKey]
  if not market and create then
    market = { items = {}, itemCount = 0, snapshots = {} }
    self.db.markets[marketKey] = market
  end
  return market
end

-- Selective reset: "history" for one market or all, "settings", "diagnostics".
-- The ledger is never cleared here.
function Store:Reset(what, marketKey)
  if what == "history" then
    if marketKey then
      self.db.markets[marketKey] = nil
    else
      self.db.markets = {}
    end
  elseif what == "settings" then
    self.db.settings = {}
    fillDefaults(self.db.settings, Store.DEFAULT_SETTINGS)
  elseif what == "diagnostics" then
    self.db.diagnostics = {}
  else
    return false
  end
  return true
end

-- Rough serialized size: enough to show occupancy and trigger pruning.
function Store.EstimateBytes(value, depth)
  depth = depth or 0
  if depth > 12 then return 0 end
  local kind = type(value)
  if kind == "string" then return #value + 4 end
  if kind == "number" then return 12 end
  if kind == "boolean" then return 6 end
  if kind ~= "table" then return 0 end
  local bytes = 4
  for key, inner in pairs(value) do
    bytes = bytes + Store.EstimateBytes(key, depth + 1) + Store.EstimateBytes(inner, depth + 1) + 4
  end
  return bytes
end
