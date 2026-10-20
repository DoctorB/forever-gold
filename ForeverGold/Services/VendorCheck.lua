-- VendorCheck: closes the loop after an assisted purchase. While a merchant
-- window is open it compares the money gained with the bag counts of items
-- bought through ForeverGold. When the money gained equals exactly
-- sold units x sellPrice, the vendor price is recorded as verified on this
-- client (runtime evidence). Selling stays manual: nothing is sold here.
local _, ns = ...

local Capabilities = ns.Core.Capabilities
local VendorCheck = {}
ns.Services.VendorCheck = VendorCheck

-- deps: { client, store, clock, printer?(report) }
function VendorCheck.New(deps)
  return setmetatable(deps, { __index = VendorCheck })
end

local function openEntries(ledger)
  local byItem = {}
  for _, entry in ipairs(ledger) do
    if entry.kind == "purchase" and entry.status == "done" and (entry.remaining or 0) > 0 and entry.itemID then
      local list = byItem[entry.itemID] or {}
      list[#list + 1] = entry
      byItem[entry.itemID] = list
    end
  end
  return byItem
end

function VendorCheck:OnMerchantShow()
  local byItem = openEntries(self.store.db.ledger)
  local counts = {}
  for itemID in pairs(byItem) do counts[itemID] = self.client:ItemCount(itemID) end
  self.visit = { money = self.client:Money(), counts = counts, t = self.clock() }
end

-- Returns a report { sold, expected, gained, match, profit } or nil.
function VendorCheck:OnMerchantClosed()
  local visit = self.visit
  self.visit = nil
  if not visit or not visit.money then return nil end
  local money = self.client:Money()
  if not money then return nil end
  local byItem = openEntries(self.store.db.ledger)
  local report = { sold = 0, expected = 0, gained = money - visit.money, profit = 0, items = 0 }
  for itemID, entries in pairs(byItem) do
    local before, after = visit.counts[itemID], self.client:ItemCount(itemID)
    if before and after and after < before then
      local sold = before - after
      for _, entry in ipairs(entries) do
        if sold <= 0 then break end
        local units = math.min(sold, entry.remaining)
        sold = sold - units
        entry.remaining = entry.remaining - units
        entry.sold = (entry.sold or 0) + units
        local revenue = units * (entry.sellPrice or 0)
        entry.revenue = (entry.revenue or 0) + revenue
        -- Cost share of the units sold, for the realized profit.
        local costShare = math.floor(entry.cost * units / entry.quantity + 0.5)
        report.sold = report.sold + units
        report.expected = report.expected + revenue
        report.profit = report.profit + revenue - costShare
      end
      report.items = report.items + 1
    end
  end
  if report.sold == 0 then return nil end
  report.match = report.gained == report.expected
  local db = self.store.db
  db.diagnostics.vendorChecks = db.diagnostics.vendorChecks or {}
  local checks = db.diagnostics.vendorChecks
  checks[#checks + 1] = { t = self.clock(), sold = report.sold, expected = report.expected, gained = report.gained }
  while #checks > 20 do table.remove(checks, 1) end
  if report.match and not Capabilities.IsVerified("sellPrice") then
    local evidence = { t = self.clock(), sold = report.sold, gained = report.gained }
    db.verifiedRuntime = db.verifiedRuntime or {}
    db.verifiedRuntime.sellPrice = evidence
    Capabilities.RecordRuntime("sellPrice", evidence)
    report.verifiedNow = true
  end
  if self.printer then self.printer(report) end
  return report
end
