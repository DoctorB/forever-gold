-- MarketValue: robust reference prices and a prudent resale price.
-- Initial, original algorithm to be calibrated with measurements (spec 7):
--   1. per interval: capped weight per listing, cheapest share of the
--      weight, weighted lower median -> one interval price;
--   2. per day: lower median of that day's interval prices (consecutive scans
--      are not independent markets);
--   3. windows 1/7/30 days: lower median of daily prices, dispersion, counts;
--   4. prudent = min(history, sustainable competition) minus a buffer, on a
--      quantity limited by observed depth.
-- Quantity on sale is depth, never "volume sold".
local _, ns = ...

local Money = ns.Economy.Money
local Depth = ns.Economy.Depth
local MarketValue = {}
ns.Economy.MarketValue = MarketValue

MarketValue.DAY = 86400
MarketValue.DEFAULTS = {
  weightCap = 5, -- units counted per listing
  cheapShareBp = 3000, -- cheapest 30% of capped weight
  minSamples = 3, -- independent days before a reference exists
  bufferBp = 500, -- prudent buffer below the reference
  liquidityBp = 2000, -- sell at most 20% of the typical listed depth at once
}

local function option(opts, key)
  if opts and opts[key] ~= nil then return opts[key] end
  return MarketValue.DEFAULTS[key]
end

local function sortedCopy(values)
  local copy = {}
  for index = 1, #values do copy[index] = values[index] end
  table.sort(copy)
  return copy
end

-- Nearest-rank quantile of a sorted list (no interpolation).
function MarketValue.Quantile(sorted, p)
  local n = #sorted
  if n == 0 then return nil end
  local rank = math.ceil(p * n)
  if rank < 1 then rank = 1 end
  if rank > n then rank = n end
  return sorted[rank]
end

-- Lower median: the conservative middle for an even count.
function MarketValue.Median(values)
  local sorted = sortedCopy(values)
  return MarketValue.Quantile(sorted, 0.5)
end

-- Per-unit price of a normalized listing, rounded down (used as a reference).
local function unitOf(listing)
  if listing.divisible then return listing.unitPrice end
  return Money.DivFloor(listing.buyoutTotal, listing.quantity)
end

-- Robust price of one observation interval. Listings without a valid buyout
-- are ignored (the bid is not a price available now).
function MarketValue.IntervalPrice(listings, opts)
  local cap = option(opts, "weightCap")
  local points, totalWeight, depth, count = {}, 0, 0, 0
  for _, entry in ipairs(Depth.Book(listings, opts)) do
    local unit = unitOf(entry)
    if unit and unit > 0 then
      local weight = math.min(entry.quantity, cap)
      points[#points + 1] = { unit = unit, weight = weight }
      totalWeight = totalWeight + weight
      depth = depth + entry.quantity
      count = count + 1
    end
  end
  if count == 0 then return nil, "no_valid_listing" end
  table.sort(points, function(a, b) return a.unit < b.unit end)
  -- Keep the cheapest share of the weight (always at least the first point).
  local keepWeight = math.max(points[1].weight, totalWeight * option(opts, "cheapShareBp") / Money.BP)
  local kept, keptWeight = {}, 0
  for _, point in ipairs(points) do
    if keptWeight >= keepWeight then break end
    kept[#kept + 1] = point
    keptWeight = keptWeight + point.weight
  end
  local half, running, price = keptWeight / 2, 0, kept[#kept].unit
  for _, point in ipairs(kept) do
    running = running + point.weight
    if running >= half then
      price = point.unit
      break
    end
  end
  return { price = price, min = points[1].unit, listings = count, depth = depth }
end

-- Estimate from a daily series { { day, price, depth } } (one entry per day).
-- Returns a table with status "ok" or "insufficient_history"; never invents
-- a reference from fewer than minSamples independent days.
function MarketValue.EstimateSeries(series, asOf, opts)
  local minSamples = option(opts, "minSamples")
  local result = { status = "insufficient_history", samples = {}, latestDay = nil }
  local today = math.floor((asOf or 0) / MarketValue.DAY)
  local windows = { 1, 7, 30 }
  local perWindow, depths = {}, {}
  for _, days in ipairs(windows) do perWindow[days] = {} end
  for _, point in ipairs(series or {}) do
    if Money.IsCopper(point.price) and point.price > 0 then
      local age = today - point.day
      if age >= 0 then
        for _, days in ipairs(windows) do
          if age < days then
            local list = perWindow[days]
            list[#list + 1] = point.price
          end
        end
        if age < 30 then depths[#depths + 1] = point.depth or 0 end
        if not result.latestDay or point.day > result.latestDay then result.latestDay = point.day end
      end
    end
  end
  for _, days in ipairs(windows) do
    local sorted = sortedCopy(perWindow[days])
    result.samples[days] = #sorted
    result["ref" .. days] = MarketValue.Quantile(sorted, 0.5)
    if days == 30 and #sorted > 0 then
      local p25, p75 = MarketValue.Quantile(sorted, 0.25), MarketValue.Quantile(sorted, 0.75)
      result.dispersionBp = math.floor((p75 - p25) * Money.BP / math.max(1, result.ref30))
    end
  end
  result.typicalDepth = MarketValue.Median(depths)
  if result.latestDay then result.ageDays = today - result.latestDay end
  -- Reference: 7-day window when it has enough days, else 30 days.
  if result.samples[7] >= minSamples then
    result.reference, result.window = result.ref7, 7
  elseif result.samples[30] >= minSamples then
    result.reference, result.window = result.ref30, 30
  end
  if result.reference then result.status = "ok" end
  return result
end

-- Contract from the spec: MarketValue:Estimate(itemKey, marketKey, asOf),
-- with the history store injected.
function MarketValue.Estimate(history, itemKey, marketKey, asOf, opts)
  return MarketValue.EstimateSeries(history:Series(marketKey, itemKey), asOf, opts)
end

-- Prudent resale for `units` already bought.
-- args: { estimate, remaining (levels after the purchase, own lots excluded)
--         or competitor (lowest remaining unit price), units, bufferBp?,
--         liquidityBp? }
-- Returns { unitPrice, sellUnits, residualUnits, prudentGross, baseGross,
--           competitor } or nil, reason.
function MarketValue.PrudentResale(args, opts)
  local estimate = args.estimate
  local competitor = args.competitor
  if competitor == nil and args.remaining then competitor = Depth.LowestUnit(args.remaining) end
  if not estimate or estimate.status ~= "ok" then
    return nil, "insufficient_history", { competitor = competitor }
  end
  local base = estimate.reference
  if competitor and competitor < base then base = competitor end
  local bufferBp = args.bufferBp or option(opts, "bufferBp")
  local unitPrice = base - Money.ShareUp(base, bufferBp)
  local depth = estimate.typicalDepth or 0
  local liquidity = math.max(1, math.floor(depth * (args.liquidityBp or option(opts, "liquidityBp")) / Money.BP))
  local sellUnits = math.min(args.units, liquidity)
  return {
    unitPrice = unitPrice,
    sellUnits = sellUnits,
    residualUnits = args.units - sellUnits,
    prudentGross = Money.Mul(unitPrice, sellUnits),
    baseGross = Money.Mul(base, args.units),
    basePrice = base,
    competitor = competitor,
    liquidity = liquidity,
  }
end
