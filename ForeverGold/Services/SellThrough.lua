-- SellThrough: what actually sells on the AH. The AH never says what was
-- bought, so each full scan is compared with the previous one: units that
-- were listed at a price and are gone 15 minutes later were (mostly) bought.
-- Expired or cancelled auctions look the same; over 15 minutes, and for the
-- cheapest lots, purchases dominate. Only for item keys with at least
-- MIN_LISTINGS auctions and without a random variant (thin and variant
-- items carry too little and too noisy data), and only between two scans
-- at most MAX_GAP apart whose row counts are close (a scan that read far
-- fewer rows - 164,639 against 252,483 in game - would make every missing
-- lot look sold).
-- Kept in ForeverGoldDB.sellThrough:
--   prev  = { t, rows, levels = { [itemKey] = "price:qty,..." } }  last scan, cheapest LEVELS prices
--   items = { [itemKey] = { h = hours watched, u = units gone, g = value gone,
--             p = { last KEEP_PRICES unit prices of units gone }, t = last update } }
local _, ns = ...

local SellThrough = {}
ns.Services.SellThrough = SellThrough

SellThrough.MIN_LISTINGS = 5
SellThrough.LEVELS = 8 -- cheapest price levels compared per item
SellThrough.MAX_GAP = 1800 -- seconds between the two scans
SellThrough.MIN_ROWS_RATIO = 0.9 -- this scan's rows / the previous scan's rows
SellThrough.KEEP_PRICES = 20
SellThrough.MAX_ITEMS = 6000
SellThrough.MIN_HOURS = 1 -- watched at least this long before showing a rate

function SellThrough.New(memory, clock)
  memory.items = memory.items or {}
  return setmetatable({ memory = memory, clock = clock }, { __index = SellThrough })
end

local function encode(levels, prices)
  local parts = {}
  for _, price in ipairs(prices) do parts[#parts + 1] = price .. ":" .. levels[price] end
  return table.concat(parts, ",")
end

local function decode(text)
  local levels = {}
  for price, quantity in string.gmatch(text or "", "(%d+):(%d+)") do levels[tonumber(price)] = tonumber(quantity) end
  return levels
end

-- Units per unit price of one item key's listings, and the prices sorted.
function SellThrough.Levels(listings)
  local levels, prices = {}, {}
  for _, listing in ipairs(listings or {}) do
    local quantity, total = listing.quantity, listing.buyoutTotal
    if listing.buyable ~= false and type(quantity) == "number" and quantity > 0 and type(total) == "number" and total > 0 then
      local unit = math.floor(total / quantity)
      if not levels[unit] then prices[#prices + 1] = unit end
      levels[unit] = (levels[unit] or 0) + quantity
    end
  end
  table.sort(prices)
  return levels, prices
end

-- Starts the comparison of a full scan. grouped: { [itemKey] = listings }.
-- Returns a job for Step / Finish.
function SellThrough:Begin(grouped, t, rows)
  local prev = self.memory.prev
  local compare = prev ~= nil and type(prev.t) == "number" and t - prev.t > 0 and t - prev.t <= SellThrough.MAX_GAP
    and type(prev.rows) == "number" and prev.rows > 0 and (rows or 0) >= prev.rows * SellThrough.MIN_ROWS_RATIO
  local keys = {}
  for itemKey, listings in pairs(grouped) do
    if #listings >= SellThrough.MIN_LISTINGS and not itemKey:find(":b", 1, true) then keys[#keys + 1] = itemKey end
  end
  table.sort(keys)
  return { keys = keys, grouped = grouped, t = t, rows = rows, compare = compare,
    hours = compare and (t - prev.t) / 3600 or 0, prevLevels = prev and prev.levels or {}, levels = {},
    compared = 0, units = 0, reason = (not compare) and (prev and "gap_or_rows" or "first") or nil }
end

function SellThrough:Step(job, index)
  local itemKey = job.keys[index]
  local levels, prices = SellThrough.Levels(job.grouped[itemKey])
  local cheapest = {}
  for i = 1, math.min(SellThrough.LEVELS, #prices) do cheapest[i] = prices[i] end
  job.levels[itemKey] = encode(levels, cheapest)
  if not job.compare then return end
  local before = job.prevLevels[itemKey]
  if not before then return end
  local stats = self.memory.items[itemKey] or { h = 0, u = 0, g = 0, p = {} }
  self.memory.items[itemKey] = stats
  stats.h = stats.h + job.hours
  stats.t = job.t
  job.compared = job.compared + 1
  for price, quantity in pairs(decode(before)) do
    local gone = quantity - (levels[price] or 0)
    if gone > 0 then
      stats.u = stats.u + gone
      stats.g = stats.g + gone * price
      job.units = job.units + gone
      stats.p[#stats.p + 1] = price
      while #stats.p > SellThrough.KEEP_PRICES do table.remove(stats.p, 1) end
    end
  end
end

function SellThrough:Finish(job)
  self.memory.prev = { t = job.t, rows = job.rows, levels = job.levels }
  -- Bounded: the items not updated for the longest time go first.
  local count, oldest = 0, {}
  for itemKey, stats in pairs(self.memory.items) do
    count = count + 1
    oldest[#oldest + 1] = { key = itemKey, t = stats.t or 0 }
  end
  if count > SellThrough.MAX_ITEMS then
    table.sort(oldest, function(a, b) return a.t < b.t end)
    for i = 1, count - SellThrough.MAX_ITEMS do self.memory.items[oldest[i].key] = nil end
  end
  self.memory.lastRun = { t = job.t, compared = job.compared, units = job.units, items = #job.keys,
    reason = job.reason }
  return self.memory.lastRun
end

-- { perHour, clearPrice, hours, units } for an item key, or nil while
-- watched less than MIN_HOURS.
function SellThrough:Stats(itemKey)
  local stats = itemKey and self.memory.items[itemKey]
  if not stats or stats.h < SellThrough.MIN_HOURS then return nil end
  local prices = {}
  for i, price in ipairs(stats.p) do prices[i] = price end
  table.sort(prices)
  return { perHour = stats.u / stats.h, clearPrice = prices[math.floor((#prices + 1) / 2)], hours = stats.h,
    units = stats.u }
end

-- { items watched, items with a rate, hours of the longest watch }.
function SellThrough:Summary()
  local watched, rated, hours = 0, 0, 0
  for _, stats in pairs(self.memory.items) do
    watched = watched + 1
    if stats.h >= SellThrough.MIN_HOURS then rated = rated + 1 end
    if stats.h > hours then hours = stats.h end
  end
  return { watched = watched, rated = rated, hours = hours, last = self.memory.lastRun }
end
