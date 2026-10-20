-- Depth: cost of buying a quantity by walking the order book level by level.
-- Never multiplies the lowest price by the whole quantity.
--
-- A level is { quantity, unitPrice? , buyoutTotal?, divisible, id? }:
--   divisible = true  a commodity level: any number of units at unitPrice;
--   divisible = false an individual auction: all `quantity` units for
--                     buyoutTotal, or nothing.
local _, ns = ...

local Money = ns.Economy.Money
local Depth = {}
ns.Economy.Depth = Depth

-- Validated copy of a level, or nil when it cannot be bought at a known price.
local function usable(level)
  if type(level) ~= "table" or not Money.IsQuantity(level.quantity) then return nil end
  -- Listings flagged unbuyable (own, incomplete, no buyout) never enter a book.
  if level.buyable == false then return nil end
  if level.divisible then
    if not Money.IsCopper(level.unitPrice) or level.unitPrice <= 0 then return nil end
    return { quantity = level.quantity, unitPrice = level.unitPrice, divisible = true, id = level.id, source = level }
  end
  if not Money.IsCopper(level.buyoutTotal) or level.buyoutTotal <= 0 then return nil end
  return { quantity = level.quantity, buyoutTotal = level.buyoutTotal, divisible = false, id = level.id, source = level }
end

-- a cheaper per unit than b, compared on totals (no rounded unit prices).
local function cheaper(a, b)
  local aTotal = a.divisible and a.unitPrice or a.buyoutTotal
  local aQty = a.divisible and 1 or a.quantity
  local bTotal = b.divisible and b.unitPrice or b.buyoutTotal
  local bQty = b.divisible and 1 or b.quantity
  local left, right = aTotal * bQty, bTotal * aQty
  if left ~= right then return left < right end
  -- Deterministic tie break: smaller indivisible lots first, then id.
  if a.quantity ~= b.quantity then return a.quantity < b.quantity end
  return tostring(a.id or "") < tostring(b.id or "")
end

-- Sorted, validated levels. opts.exclude: set of level ids to skip (own
-- auctions, the candidate lots already counted elsewhere).
function Depth.Book(levels, opts)
  local exclude = opts and opts.exclude
  local book, skipped = {}, 0
  for _, level in ipairs(levels or {}) do
    local entry = usable(level)
    if entry and not (exclude and entry.id ~= nil and exclude[entry.id]) then
      book[#book + 1] = entry
    else
      skipped = skipped + 1
    end
  end
  table.sort(book, cheaper)
  return book, skipped
end

-- Cost of acquiring at least `quantity` units. Indivisible lots may push the
-- acquired quantity above the request; the result reports it.
-- Returns { cost, quantity, complete, used = { { level, units, cost } } }.
function Depth.BuyCost(levels, quantity, opts)
  if not Money.IsQuantity(quantity) then return nil, "invalid_quantity" end
  local book = Depth.Book(levels, opts)
  local result = { cost = 0, quantity = 0, complete = false, used = {} }
  for _, level in ipairs(book) do
    if result.quantity >= quantity then break end
    local units, cost
    if level.divisible then
      units = math.min(level.quantity, quantity - result.quantity)
      cost = Money.Mul(level.unitPrice, units)
    else
      units = level.quantity
      cost = level.buyoutTotal
    end
    local total = cost and Money.Add(result.cost, cost)
    if not total then return nil, "out_of_range" end
    result.cost = total
    result.quantity = result.quantity + units
    result.used[#result.used + 1] = { level = level.source, units = units, cost = cost }
  end
  result.complete = result.quantity >= quantity
  return result
end

-- Total units purchasable at a known price.
function Depth.Available(levels, opts)
  local total = 0
  for _, level in ipairs(Depth.Book(levels, opts)) do
    total = total + level.quantity
  end
  return total
end

-- Lowest per-unit price (rounded up) among remaining levels, or nil.
function Depth.LowestUnit(levels, opts)
  local book = Depth.Book(levels, opts)
  local first = book[1]
  if not first then return nil end
  if first.divisible then return first.unitPrice end
  return Money.DivCeil(first.buyoutTotal, first.quantity)
end

-- Levels left after removing the units consumed by a BuyCost result.
function Depth.Remaining(levels, purchase, opts)
  local consumed = {}
  for _, use in ipairs(purchase and purchase.used or {}) do
    consumed[use.level] = (consumed[use.level] or 0) + use.units
  end
  local rest = {}
  for _, level in ipairs(Depth.Book(levels, opts)) do
    local left = level.quantity - (consumed[level.source] or 0)
    if left > 0 then
      if level.divisible then
        rest[#rest + 1] = { quantity = left, unitPrice = level.unitPrice, divisible = true, id = level.id }
      else
        rest[#rest + 1] = level.source
      end
    end
  end
  return rest
end
