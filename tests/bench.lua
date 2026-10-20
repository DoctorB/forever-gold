-- Offline benchmark: history recording and opportunity evaluation on a
-- synthetic AH of 30,000 rows over 3,000 item keys, with 10 days of history.
--   lua5.1 tests/bench.lua
-- Desktop Lua 5.1 timings are only an order of magnitude: frame time and
-- memory must be measured in the client (docs/TESTING-IN-GAME.md).
local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\]bench%.lua$") or "."
T = { ROOT = ROOT, ADDON_DIR = ROOT .. "/ForeverGold" }
function T.ReadFile(path)
  local handle = assert(io.open(path, "rb"))
  local data = handle:read("*a")
  handle:close()
  return data
end
function T.TocEntries()
  local entries = {}
  for line in (T.ReadFile(T.ADDON_DIR .. "/ForeverGold.toc") .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    if line:match("%S") and not line:match("^#") then entries[#entries + 1] = line end
  end
  return entries
end
local ns = {}
for _, entry in ipairs(T.TocEntries()) do
  assert(loadfile(T.ADDON_DIR .. "/" .. entry:gsub("\\", "/")))("ForeverGold", ns)
end

local Schema, Store, History = ns.Data.Schema, ns.Data.Store, ns.Data.History
local DAY = ns.Economy.MarketValue.DAY
local MARKET = Schema.MarketKey({ product = "p18", region = 3, realm = "Bench", faction = "Alliance" })
local KEYS, ROWS = 3000, 30000
local now = 20000 * DAY
math.randomseed(12345)
local random = math.random

local function rows(t, scanId)
  local list = {}
  for index = 1, ROWS do
    local itemID = random(KEYS)
    local quantity = random(20)
    local unit = 50 + (itemID % 400) * 10 + random(40)
    list[index] = Schema.NewListing({ marketKey = MARKET, itemKey = Schema.ItemKey(itemID, 0), quantity = quantity,
      buyoutTotal = unit * quantity, divisible = false, source = "replicate", scanId = scanId, index = index, seen = t })
  end
  return list
end

local store = Store.New(nil, { now = now })
local history = History.New(store, function() return now end)
local started = os.clock()
for back = 10, 1, -1 do
  local t = now - back * DAY
  history:Record({ id = "b" .. back, marketKey = MARKET, coverage = "full_unverified", finished = t }, rows(t, "b" .. back))
end
local recordSeconds = (os.clock() - started) / 10

local items = {}
function items.Read(_, itemID) return { itemID = itemID, name = "Item " .. itemID, sellPrice = 40 + itemID % 300, classID = itemID % 15 } end
function items.Resolve(self, itemID, callback) callback(self:Read(itemID)) end
local opportunities = ns.Services.Opportunities.New({ store = store, history = history, items = items, clock = function() return now end })
local snapshot = Schema.NewSnapshot({ id = "now", marketKey = MARKET, mode = "replicate", scope = "all", started = now })
snapshot.finished, snapshot.coverage = now, "full_unverified"
local current = rows(now, "now")
collectgarbage("collect")
local memoryBefore = collectgarbage("count")
started = os.clock()
opportunities:Ingest(snapshot, current)
local results = opportunities:Evaluate()
local evaluateSeconds = os.clock() - started
local bytes = Store.EstimateBytes(store.db.markets)

print(string.format("history record: %.3f s per 30,000-row snapshot", recordSeconds))
print(string.format("evaluate: %.3f s for %d item keys, %d rows -> %d opportunities", evaluateSeconds,
  results.counts.itemKeys, results.counts.listings, results.counts.opportunities))
print(string.format("estimated history size after 10 days: %d KB (budget %d KB)", bytes / 1024,
  Store.RETENTION.budgetBytes / 1024))
print(string.format("Lua heap: %d KB (+%d KB during evaluation)", collectgarbage("count"),
  collectgarbage("count") - memoryBefore))
