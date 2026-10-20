-- Costs: profit, ROI and break-even for one lot (spec section 8).
--   B  purchase cost of the whole lot      R  gross resale revenue
--   f  sale fee in basis points            L  expected lost deposits
--   X  other real costs (reagents, conversions)
--   profit = R * (1 - f) - B - L - X
--   ROI    = profit / (B + X)  when B + X > 0
--   R_BE   = (B + L + X) / (1 - f)  for 0 <= f < 1
-- Costs are rounded up and revenues down. Returns nil, reason on any unknown.
local _, ns = ...

local Money = ns.Economy.Money
local Costs = {}
ns.Economy.Costs = Costs

local function validFee(feeBp)
  return type(feeBp) == "number" and feeBp >= 0 and feeBp < Money.BP and math.floor(feeBp) == feeBp
end

-- Revenue after the sale fee (fee rounded up as a cost).
function Costs.NetRevenue(gross, feeBp)
  if not Money.IsCopper(gross) then return nil, "revenue_unknown" end
  if not validFee(feeBp) then return nil, "fee_unknown" end
  local fee = Money.ShareUp(gross, feeBp)
  return gross - fee, fee
end

-- Minimum gross revenue whose net covers `need` copper.
function Costs.BreakEven(need, feeBp)
  if not Money.IsCopper(need) then return nil, "cost_unknown" end
  if not validFee(feeBp) then return nil, "fee_unknown" end
  local gross = Money.DivCeil(Money.Mul(need, Money.BP), Money.BP - feeBp)
  -- Fee rounding may leave the net one copper short: step up until covered.
  while (Costs.NetRevenue(gross, feeBp)) < need do gross = gross + 1 end
  return gross
end

-- Full evaluation of one lot. args: { B, R, feeBp, L, X }.
-- L and X default to nothing only when explicitly passed as 0.
function Costs.Evaluate(args)
  local B, R, L, X = args.B, args.R, args.L, args.X
  if not Money.IsCopper(B) then return nil, "purchase_unknown" end
  if not Money.IsCopper(L) then return nil, "deposit_loss_unknown" end
  if not Money.IsCopper(X) then return nil, "extra_cost_unknown" end
  local net, fee = Costs.NetRevenue(R, args.feeBp)
  if not net then return nil, fee end
  local outlay = B + L + X
  local result = {
    gross = R,
    fee = fee,
    net = net,
    outlay = outlay,
    profit = net - outlay,
    breakEven = Costs.BreakEven(outlay, args.feeBp),
  }
  local base = B + X
  if base > 0 then result.roi = result.profit / base end
  return result
end

-- A deposit refunded on sale only immobilises capital; a lost one is a cost.
function Costs.Deposit(amount, refunded)
  if not Money.IsCopper(amount) then return nil, "deposit_unknown" end
  return { capital = amount, cost = refunded and 0 or amount }
end
