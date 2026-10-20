-- History: local price observations per market and item key.
-- Different markets or variants never share a series. Disappearing listings
-- are not read as sales: only listed prices and depth are stored.
local _, ns = ...

local MarketValue = ns.Economy.MarketValue
local Store = ns.Data.Store
local History = {}
ns.Data.History = History

local DAY = MarketValue.DAY
local MAX_INTERVALS_PER_DAY = 24
History.MAX_RECENT_PER_ITEM = 20 -- detailed observations kept per item key

function History.New(store, clock)
  return setmetatable({ store = store, clock = clock }, { __index = History })
end

local function lowerMedian(values)
  return MarketValue.Median(values)
end

-- Recording is split in steps (one item key each) so the client can spread
-- a large snapshot over several frames; Record runs all steps at once.
-- snapshot: { id, marketKey, coverage, finished }
-- listings: normalized listings (Schema.NewListing)
function History:BeginRecord(snapshot, listings)
  local now = snapshot.finished or self.clock()
  local job = {
    snapshot = snapshot, now = now, day = math.floor(now / DAY), byItem = {}, order = {}, updated = 0,
    market = self.store:Market(snapshot.marketKey, true), partial = snapshot.coverage ~= "full_verified",
  }
  for _, listing in ipairs(listings) do
    if listing.buyable and listing.marketKey == snapshot.marketKey then
      local list = job.byItem[listing.itemKey]
      if not list then
        list = {}
        job.byItem[listing.itemKey] = list
        job.order[#job.order + 1] = listing.itemKey
      end
      list[#list + 1] = listing
    end
  end
  return job
end

function History.RecordStep(job, index)
  local itemKey = job.order[index]
  local interval = MarketValue.IntervalPrice(job.byItem[itemKey])
  if not interval then return end
  local market, now = job.market, job.now
  local item = market.items[itemKey]
  if not item then
    item = { days = {}, recent = {} }
    market.items[itemKey] = item
    market.itemCount = (market.itemCount or 0) + 1
  end
  item.lastSeen = now
  item.recent[#item.recent + 1] = {
    t = now, price = interval.price, min = interval.min, depth = interval.depth,
    listings = interval.listings, partial = job.partial or nil, scan = job.snapshot.id,
  }
  while #item.recent > History.MAX_RECENT_PER_ITEM do table.remove(item.recent, 1) end
  local bucket = item.days[job.day]
  if not bucket then
    bucket = { p = {}, depth = {}, partial = 0 }
    item.days[job.day] = bucket
  end
  if #bucket.p < MAX_INTERVALS_PER_DAY then
    bucket.p[#bucket.p + 1] = interval.price
    bucket.depth[#bucket.depth + 1] = interval.depth
  end
  if job.partial then bucket.partial = bucket.partial + 1 end
  bucket.price = lowerMedian(bucket.p)
  bucket.depthMedian = lowerMedian(bucket.depth)
  bucket.min = math.min(bucket.min or interval.min, interval.min)
  job.updated = job.updated + 1
end

-- Returns the number of item keys updated.
function History.FinishRecord(job)
  local market, snapshot = job.market, job.snapshot
  market.snapshots[#market.snapshots + 1] = {
    id = snapshot.id, t = job.now, mode = snapshot.mode, coverage = snapshot.coverage, items = job.updated,
    started = snapshot.started, status = snapshot.status, reason = snapshot.reason, indexBase = snapshot.indexBase,
    counts = snapshot.counts, discardReasons = snapshot.discardReasons, updates = snapshot.updates,
    lateUpdates = snapshot.lateUpdates, rounds = snapshot.rounds,
    samples = snapshot.samples and #snapshot.samples > 0 and snapshot.samples or nil,
    links = snapshot.links and #snapshot.links > 0 and snapshot.links or nil,
  }
  while #market.snapshots > 50 do table.remove(market.snapshots, 1) end
  -- Evidence lists are only needed on the most recent snapshots.
  for index = 1, #market.snapshots - 5 do
    market.snapshots[index].samples, market.snapshots[index].links = nil, nil
  end
  return job.updated
end

function History:Record(snapshot, listings)
  local job = self:BeginRecord(snapshot, listings)
  for index = 1, #job.order do History.RecordStep(job, index) end
  return History.FinishRecord(job)
end

-- Daily series for MarketValue.EstimateSeries.
function History:Series(marketKey, itemKey)
  local market = self.store:Market(marketKey, false)
  local item = market and market.items[itemKey]
  local series = {}
  if not item then return series end
  for day, bucket in pairs(item.days) do
    series[#series + 1] = { day = day, price = bucket.price, depth = bucket.depthMedian, partial = bucket.partial }
  end
  table.sort(series, function(a, b) return a.day < b.day end)
  return series
end

function History:Item(marketKey, itemKey)
  local market = self.store:Market(marketKey, false)
  return market and market.items[itemKey]
end

-- Retention: details 7 days, daily aggregates 90 days, at most maxKeys item
-- keys per market (least recently seen, unwatched first). The ledger is not
-- touched. Returns counts of removed entries.
function History:Prune(now, watched)
  local retention = Store.RETENTION
  local removed = { recent = 0, days = 0, items = 0 }
  local today = math.floor(now / DAY)
  for _, market in pairs(self.store.db.markets) do
    local keys = {}
    for itemKey, item in pairs(market.items) do
      local kept = {}
      for _, entry in ipairs(item.recent) do
        if now - entry.t < retention.recentDays * DAY then
          kept[#kept + 1] = entry
        else
          removed.recent = removed.recent + 1
        end
      end
      item.recent = kept
      for day in pairs(item.days) do
        if today - day >= retention.dailyDays then
          item.days[day] = nil
          removed.days = removed.days + 1
        end
      end
      keys[#keys + 1] = itemKey
    end
    if #keys > retention.maxKeys then
      table.sort(keys, function(a, b)
        local aw, bw = watched and watched[a] and 1 or 0, watched and watched[b] and 1 or 0
        if aw ~= bw then return aw < bw end
        return (market.items[a].lastSeen or 0) < (market.items[b].lastSeen or 0)
      end)
      for index = 1, #keys - retention.maxKeys do
        market.items[keys[index]] = nil
        removed.items = removed.items + 1
      end
    end
    local count = 0
    for _ in pairs(market.items) do count = count + 1 end
    market.itemCount = count
  end
  -- Over the size budget: drop detailed observations, keep daily aggregates.
  if Store.EstimateBytes(self.store.db.markets) > retention.budgetBytes then
    for _, market in pairs(self.store.db.markets) do
      for _, item in pairs(market.items) do
        removed.recent = removed.recent + #item.recent
        item.recent = {}
      end
    end
    removed.overBudget = true
  end
  return removed
end
