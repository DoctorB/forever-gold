-- Deposit: AH deposit estimated from the merchant price. Pure.
--   deposit = max(MINIMUM, ceil(sellPrice * quantity * rate(duration)))
-- Durations 1/2/3 = 2/8/24 h on Forever. One measurement backs it (audit
-- rows 14-15, 20 Copper Bars, merchant price 10): quotes 100 / 100 / 120,
-- i.e. 60% for 24 h and a 100-copper minimum; the 15% / 30% rates of 2 / 8 h
-- are the modern AH ones and only bounded by that minimum. Every quote the
-- client gives for an item in the bags is compared with this formula
-- (Services/DepositCheck); until enough of them match it stays "estimated".
-- A commodity is posted as one auction (one minimum); other items as one
-- auction per stack (stackSize units, one minimum each): in game counting
-- one auction per unit charged 20 Copper Rods (stacks of 20) twenty
-- minimums and removed every Blacksmithing recipe from the list.
local _, ns = ...

local Money = ns.Economy.Money
local Deposit = {}
ns.Economy.Deposit = Deposit

Deposit.RATES_BP = { 1500, 3000, 6000 }
Deposit.MINIMUM = 100
Deposit.DEFAULT_DURATION = 2 -- 8 h, the AH window's default on Forever

-- Deposit of one auction of `quantity` units, or nil, reason.
function Deposit.Estimate(sellPrice, quantity, duration)
  local rate = Deposit.RATES_BP[duration or Deposit.DEFAULT_DURATION]
  if not rate then return nil, "duration" end
  if not Money.IsCopper(sellPrice) then return nil, "sell_price_unknown" end
  if not Money.IsQuantity(quantity) then return nil, "quantity" end
  local raw = Money.DivCeil(Money.Mul(sellPrice, quantity) * rate, Money.BP)
  if raw < Deposit.MINIMUM then return Deposit.MINIMUM end
  return raw
end

-- Deposit for selling `units` units: one auction for a commodity, one per
-- full or partial stack otherwise. Returns copper or nil, reason.
function Deposit.ForUnits(sellPrice, units, commodity, duration, stackSize)
  if not Money.IsQuantity(units) then return nil, "quantity" end
  if commodity == true then return Deposit.Estimate(sellPrice, units, duration) end
  local stack = (type(stackSize) == "number" and stackSize >= 1) and math.floor(stackSize) or 1
  local full, rest = math.floor(units / stack), units % stack
  local total = 0
  if full > 0 then
    local one, reason = Deposit.Estimate(sellPrice, stack, duration)
    if not one then return nil, reason end
    total = total + one * full
  end
  if rest > 0 then
    local last, reason = Deposit.Estimate(sellPrice, rest, duration)
    if not last then return nil, reason end
    total = total + last
  end
  return total
end

-- Expected loss: the deposit comes back on a sale and is kept by the AH
-- when the auction expires; lossBp is the share assumed lost.
function Deposit.ExpectedLoss(deposit, lossBp)
  if not Money.IsCopper(deposit) then return nil end
  return Money.ShareUp(deposit, lossBp)
end
