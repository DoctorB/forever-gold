-- Migrations: versioned, idempotent, applied to a copy.
-- The live table is replaced only when every step succeeds; content that a
-- step cannot interpret is kept under `recovered`, never silently dropped.
local _, ns = ...

local Migrations = {}
ns.Data.Migrations = Migrations

Migrations.CURRENT = 2

-- steps[n] upgrades a table at version n - 1 to version n.
Migrations.steps = {
  [1] = function(db)
    -- Unversioned content: keep it aside, start a clean v1 layout.
    local old = {}
    local any = false
    for key, value in pairs(db) do
      old[key] = value
      any = true
    end
    for key in pairs(old) do db[key] = nil end
    if any then db.recovered = { fromVersion = 0, data = old } end
    db.schema = 1
  end,
  [2] = function(db)
    -- 0.1.0-alpha.2 showed vendor margins of 1 copper: raise the old default.
    if type(db.settings) == "table" and db.settings.minVendorProfit == 1 then db.settings.minVendorProfit = 25 end
  end,
}

-- Returns migrated table, report. Report fields: from, to, applied (list),
-- readOnly (newer schema than this build), error.
function Migrations.Run(db, copyTable)
  local report = { from = db and db.schema or 0, to = Migrations.CURRENT, applied = {} }
  if type(db) ~= "table" then
    report.from = 0
    db = {}
  end
  local from = tonumber(db.schema) or 0
  report.from = from
  if from > Migrations.CURRENT then
    -- Written by a newer version: never downgrade, run without saving.
    report.readOnly = true
    return db, report
  end
  if from == Migrations.CURRENT then return db, report end
  local work = copyTable(db)
  local ok, err = pcall(function()
    for version = from + 1, Migrations.CURRENT do
      Migrations.steps[version](work)
      work.schema = version
      report.applied[#report.applied + 1] = version
    end
  end)
  if not ok then
    report.error = tostring(err)
    report.readOnly = true
    return db, report
  end
  return work, report
end
