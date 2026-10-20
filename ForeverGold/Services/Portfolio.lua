-- Portfolio: realized gains from the purchase ledger. Pure: reads ledger
-- entries written by Services/Purchases and updated by Services/VendorCheck.
-- Realized gain counts only units actually sold; units still in the bags are
-- inventory with an expected value, not profit.
local _, ns = ...

local Portfolio = {}
ns.Services.Portfolio = Portfolio

local function costOf(entry, units)
  if not entry.quantity or entry.quantity <= 0 then return 0 end
  return math.floor(entry.cost * units / entry.quantity + 0.5)
end

-- Returns { totals = {...}, entries = { newest first } }.
function Portfolio.Report(ledger)
  local totals = {
    purchases = 0, spent = 0, revenue = 0, realized = 0, soldUnits = 0,
    pendingUnits = 0, pendingCost = 0, pendingExpected = 0, uncertain = 0,
  }
  local entries = {}
  for index = #(ledger or {}), 1, -1 do
    local entry = ledger[index]
    if entry.kind == "purchase" then
      local row = {
        t = entry.t, name = entry.name or entry.itemKey, quantity = entry.quantity or 0, cost = entry.cost or 0,
        sold = entry.sold or 0, revenue = entry.revenue or 0, remaining = entry.remaining or 0, status = entry.status,
      }
      if entry.status == "done" then
        totals.purchases = totals.purchases + 1
        totals.spent = totals.spent + row.cost
        local soldCost = costOf(entry, row.sold)
        row.realized = row.revenue - soldCost
        totals.revenue = totals.revenue + row.revenue
        totals.realized = totals.realized + row.realized
        totals.soldUnits = totals.soldUnits + row.sold
        if row.remaining > 0 then
          row.pendingCost = row.cost - soldCost
          row.pendingExpected = entry.sellPrice and entry.sellPrice * row.remaining or nil
          totals.pendingUnits = totals.pendingUnits + row.remaining
          totals.pendingCost = totals.pendingCost + row.pendingCost
          totals.pendingExpected = totals.pendingExpected + (row.pendingExpected or 0)
        end
      elseif entry.status == "uncertain" then
        totals.uncertain = totals.uncertain + 1
      end
      entries[#entries + 1] = row
    end
  end
  return { totals = totals, entries = entries }
end
