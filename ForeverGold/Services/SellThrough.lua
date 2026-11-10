-- SellThrough: what actually sells on the AH. The AH never says what was
-- bought, so each full scan is compared with the previous one: units that
-- were listed at a price and are gone 15 minutes later were (mostly) bought.
-- A stack that vanished while a stack of the same size appeared at another
-- price was relisted, not bought (in game, 2026-11-10, counting without this
-- made 3,120 Silk Cloth "sell" in 35 minutes); new units at the same price
-- are taken off what vanished there (a partly bought commodity auction).
-- Expired auctions that are not relisted still count as sold (accepted).
-- Only for item keys with at least MIN_LISTINGS auctions and without a
-- random variant (thin and variant items carry too little and too noisy
-- data), and only between two scans at most MAX_GAP apart whose row counts
-- are close (a scan that read far fewer rows - 164,639 against 252,483 in
-- game - would make every missing lot look sold).
-- Kept in ForeverGoldDB.sellThrough:
--   version = VERSION (older data, counted without the relist check, is dropped)
--   prev  = { t, rows, levels = { [itemKey] = "price:SIZExSTACKS/...,..." } }  last scan, cheapest LEVELS prices
--   items = { [itemKey] = { h = hours watched, u = units gone, g = value gone,
--             p = { last KEEP_PRICES unit prices of units gone }, t = last update } }
--   vendorLots = { t, lots = { [signature] = count }, prevT, prevLots }  merchant offers of the last two full scans
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
SellThrough.VERSION = 2

function SellThrough.New(memory, clock)
  if memory.version ~= SellThrough.VERSION then
    memory.items, memory.prev, memory.lastRun, memory.version = {}, nil, nil, SellThrough.VERSION
  end
  memory.items = memory.items or {}
  return setmetatable({ memory = memory, clock = clock }, { __index = SellThrough })
end

local function sortedKeys(map)
  local keys = {}
  for key in pairs(map) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys
end

-- One price level is { [stack size] = stacks }.
local function encode(levels, prices)
  local parts = {}
  for _, price in ipairs(prices) do
    local stacks = {}
    for i, size in ipairs(sortedKeys(levels[price])) do stacks[i] = size .. "x" .. levels[price][size] end
    parts[#parts + 1] = price .. ":" .. table.concat(stacks, "/")
  end
  return table.concat(parts, ",")
end

local function decode(text)
  local levels = {}
  for price, stacks in string.gmatch(text or "", "(%d+):([%dx/]+)") do
    local level = {}
    for size, count in string.gmatch(stacks, "(%d+)x(%d+)") do level[tonumber(size)] = tonumber(count) end
    levels[tonumber(price)] = level
  end
  return levels
end

-- Stacks per unit price of one item key's listings ({ [price] = { [size] =
-- stacks } }), and the prices sorted.
function SellThrough.Levels(listings)
  local levels, prices = {}, {}
  for _, listing in ipairs(listings or {}) do
    local quantity, total = listing.quantity, listing.buyoutTotal
    if listing.buyable ~= false and type(quantity) == "number" and quantity > 0 and type(total) == "number" and total > 0 then
      local unit = math.floor(total / quantity)
      local level = levels[unit]
      if not level then
        level = {}
        levels[unit] = level
        prices[#prices + 1] = unit
      end
      level[quantity] = (level[quantity] or 0) + 1
    end
  end
  table.sort(prices)
  return levels, prices
end

-- Units sold per price between two scans of one item key. before: the
-- cheapest levels of the previous scan; after: all levels now (both
-- { [price] = { [size] = stacks } }). Returns { [price] = units }.
function SellThrough.Sold(before, after)
  local beforePrices = sortedKeys(before)
  -- Only the cheapest LEVELS prices were kept: a stack above them may be old.
  local ceiling = #beforePrices >= SellThrough.LEVELS and beforePrices[#beforePrices] or math.huge
  local vanished, appeared = {}, {} -- [price] = { [size] = stacks }
  for _, price in ipairs(beforePrices) do
    local now = after[price] or {}
    for size, count in pairs(before[price]) do
      local gone = count - (now[size] or 0)
      if gone > 0 then
        vanished[price] = vanished[price] or {}
        vanished[price][size] = gone
      end
    end
  end
  for price, level in pairs(after) do
    if price <= ceiling then
      local was = before[price] or {}
      for size, count in pairs(level) do
        local new = count - (was[size] or 0)
        if new > 0 then
          appeared[price] = appeared[price] or {}
          appeared[price][size] = new
        end
      end
    end
  end
  -- Relists: a vanished stack matched by a new stack of the same size at
  -- another price, cheapest first.
  local appearedPrices = sortedKeys(appeared)
  for _, price in ipairs(beforePrices) do
    local level = vanished[price]
    for _, size in ipairs(level and sortedKeys(level) or {}) do
      for _, other in ipairs(appearedPrices) do
        local new = other ~= price and appeared[other][size]
        if new and new > 0 then
          local matched = math.min(new, level[size])
          appeared[other][size] = new - matched
          level[size] = level[size] - matched
          if level[size] == 0 then break end
        end
      end
    end
  end
  local sold = {}
  for _, price in ipairs(beforePrices) do
    local gone, new = 0, 0
    for size, count in pairs(vanished[price] or {}) do gone = gone + size * count end
    for size, count in pairs(appeared[price] or {}) do new = new + size * count end
    if gone > new then sold[price] = gone - new end
  end
  return sold
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
  local sold = SellThrough.Sold(decode(before), levels)
  for _, price in ipairs(sortedKeys(sold)) do
    local gone = sold[price]
    stats.u = stats.u + gone
    stats.g = stats.g + gone * price
    job.units = job.units + gone
    stats.p[#stats.p + 1] = price
    while #stats.p > SellThrough.KEEP_PRICES do table.remove(stats.p, 1) end
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
-- watched less than MIN_HOURS. clearPrice is nil when nothing sold.
function SellThrough:Stats(itemKey)
  local stats = itemKey and self.memory.items[itemKey]
  if not stats or stats.h < SellThrough.MIN_HOURS then return nil end
  local prices = {}
  for i, price in ipairs(stats.p) do prices[i] = price end
  table.sort(prices)
  return { perHour = stats.u / stats.h, clearPrice = prices[math.floor((#prices + 1) / 2)], hours = stats.h,
    units = stats.u }
end

-- Merchant offers seen again: marks each vendor offer's lots that were
-- already offered at the previous full scan (at most MAX_GAP before) with
-- lot.persisted and the offer with persisted = units in such lots. In game
-- 9 of 10 fresh lots were gone at the click (2026-11-08); a lot nobody took
-- for a whole scan interval is more likely still there. Only full scans
-- (t = the scan time) replace the remembered lots.
local function signature(lot)
  local listing = lot.listing or {}
  return tostring(listing.itemKey) .. "|" .. tostring(listing.quantity) .. "|" .. tostring(listing.buyoutTotal)
end

-- t: time of the full scan the list comes from (full = true) or nil for an
-- evaluation after a search; the same full scan can be evaluated again.
function SellThrough:MarkPersisted(list, t, full)
  local memory = self.memory.vendorLots or {}
  self.memory.vendorLots = memory
  local fresh = full and type(t) == "number" and t ~= memory.t
  local left, seen = {}, {}
  local usable = type(memory.prevT) == "number" and type(memory.t) == "number"
    and memory.t - memory.prevT > 0 and memory.t - memory.prevT <= SellThrough.MAX_GAP
  if fresh then
    usable = type(memory.t) == "number" and t - memory.t > 0 and t - memory.t <= SellThrough.MAX_GAP
    if usable then for key, count in pairs(memory.lots or {}) do left[key] = count end end
  elseif usable then
    for key, count in pairs(memory.prevLots or {}) do left[key] = count end
  end
  for _, o in ipairs(list or {}) do
    if o.strategy == "vendor" then
      o.persisted = 0
      for _, lot in ipairs(o.lots or {}) do
        local key = signature(lot)
        seen[key] = (seen[key] or 0) + 1
        if (left[key] or 0) > 0 then
          left[key] = left[key] - 1
          lot.persisted = true
          o.persisted = o.persisted + (lot.quantity or 0)
        end
      end
    end
  end
  if fresh then
    memory.prevT, memory.prevLots, memory.t, memory.lots = memory.t, memory.lots, t, seen
  end
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
