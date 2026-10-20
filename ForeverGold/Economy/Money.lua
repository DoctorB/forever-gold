-- Money: integer copper arithmetic with explicit unknowns.
-- nil is never turned into zero; every helper returns nil plus a reason when
-- an input is missing or outside the safe integer range of a Lua 5.1 double.
local _, ns = ...

local Money = {}
ns.Economy.Money = Money

local floor = math.floor

-- Largest integer represented exactly by a double (2^53 - 1).
Money.MAX_SAFE = 9007199254740991
Money.BP = 10000 -- basis points in one whole
Money.COPPER_PER_SILVER = 100
Money.COPPER_PER_GOLD = 10000

local function isInteger(value)
  return type(value) == "number" and value == value and value ~= math.huge
    and value ~= -math.huge and floor(value) == value
end

-- Non-negative copper amount within the safe range.
function Money.IsCopper(value)
  return isInteger(value) and value >= 0 and value <= Money.MAX_SAFE
end

-- Positive whole quantity of units.
function Money.IsQuantity(value)
  return isInteger(value) and value > 0 and value <= 1000000
end

-- Accepts what the client hands over and returns copper or nil, reason.
-- Only plain numbers are supported: any other type (for example an opaque
-- big integer) is rejected rather than converted lossily.
function Money.Normalize(value)
  if value == nil then return nil, "missing" end
  if type(value) ~= "number" then return nil, "unsupported_type" end
  if value ~= value or value == math.huge or value == -math.huge then return nil, "not_finite" end
  if value < 0 then return nil, "negative" end
  if floor(value) ~= value then return nil, "fractional" end
  if value > Money.MAX_SAFE then return nil, "out_of_range" end
  return value
end

function Money.Add(a, b)
  if not (Money.IsCopper(a) and Money.IsCopper(b)) then return nil, "invalid" end
  local sum = a + b
  if sum > Money.MAX_SAFE then return nil, "out_of_range" end
  return sum
end

-- a * b for a copper amount and a whole multiplier.
function Money.Mul(a, b)
  if not (Money.IsCopper(a) and isInteger(b) and b >= 0) then return nil, "invalid" end
  if b ~= 0 and a > Money.MAX_SAFE / b then return nil, "out_of_range" end
  return a * b
end

-- Exact integer floor(a / b) for a >= 0, b > 0, corrected for float error.
function Money.DivFloor(a, b)
  if not (Money.IsCopper(a) and isInteger(b) and b > 0) then return nil, "invalid" end
  local q = floor(a / b)
  while q > 0 and q * b > a do q = q - 1 end
  while (q + 1) * b <= a do q = q + 1 end
  return q
end

function Money.DivCeil(a, b)
  local q, reason = Money.DivFloor(a, b)
  if not q then return nil, reason end
  if q * b < a then q = q + 1 end
  return q
end

-- Rounds a share of an amount, in basis points, towards a cost (up) or a
-- revenue (down). Large amounts are split to keep products exact.
local function share(amount, bp, roundUp)
  if not (Money.IsCopper(amount) and isInteger(bp) and bp >= 0) then return nil, "invalid" end
  local whole = Money.DivFloor(amount, Money.BP)
  local rest = amount - whole * Money.BP
  local exact = whole * bp
  local partial = rest * bp
  local add = roundUp and Money.DivCeil(partial, Money.BP) or Money.DivFloor(partial, Money.BP)
  return exact + add
end

function Money.ShareUp(amount, bp)
  return share(amount, bp, true)
end

function Money.ShareDown(amount, bp)
  return share(amount, bp, false)
end

-- Converts a fraction such as 0.05 to basis points; only exact values allowed.
function Money.ToBasisPoints(fraction)
  if type(fraction) ~= "number" or fraction ~= fraction then return nil end
  local bp = floor(fraction * Money.BP + 0.5)
  if math.abs(bp - fraction * Money.BP) > 1e-6 then return nil end
  return bp
end

-- Human readable amount; unknown values stay visibly unknown.
function Money.Format(copper, unknownText)
  if copper == nil then return unknownText or "?" end
  if type(copper) ~= "number" then return unknownText or "?" end
  local sign = ""
  if copper < 0 then
    sign = "-"
    copper = -copper
  end
  local gold = floor(copper / Money.COPPER_PER_GOLD)
  local silver = floor((copper - gold * Money.COPPER_PER_GOLD) / Money.COPPER_PER_SILVER)
  local rest = copper - gold * Money.COPPER_PER_GOLD - silver * Money.COPPER_PER_SILVER
  local parts = {}
  if gold > 0 then parts[#parts + 1] = gold .. "g" end
  if silver > 0 or gold > 0 then parts[#parts + 1] = silver .. "s" end
  parts[#parts + 1] = rest .. "c"
  return sign .. table.concat(parts, " ")
end

-- Basis points as a percentage string, e.g. 1500 -> "15.0%".
function Money.FormatBp(bp)
  if type(bp) ~= "number" then return "?" end
  return string.format("%.1f%%", bp / 100)
end
