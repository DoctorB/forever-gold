-- Schema: normalized records shared by scanner, history and strategies.
-- Pure: never reads client globals; adapters hand over plain values.
local _, ns = ...

local Money = ns.Economy.Money
local Schema = {}
ns.Data.Schema = Schema

Schema.VERSION = 1
Schema.MODEL = 1 -- market model version inside MarketKey
Schema.UNKNOWN = "?"

local function part(value)
  if value == nil or value == "" then return Schema.UNKNOWN end
  return (tostring(value):gsub("[|:]", "_"))
end

-- MarketKey: an unknown field is a separate partition, never "global".
-- fields: { product, region, realm, faction }
function Schema.MarketKey(fields)
  fields = fields or {}
  return table.concat({
    "m" .. Schema.MODEL, part(fields.product), part(fields.region), part(fields.realm), part(fields.faction),
  }, "|")
end

-- ItemKey from verified parts; variantUnknown when the source could not
-- expose a variant that matters (e.g. missing link for a suffix item).
function Schema.ItemKey(itemID, suffix, variantUnknown)
  if type(itemID) ~= "number" or itemID <= 0 or math.floor(itemID) ~= itemID then return nil end
  if variantUnknown then return "i:" .. itemID .. ":?" end
  local s = tonumber(suffix) or 0
  return "i:" .. itemID .. ":" .. s
end

function Schema.ItemIDOf(itemKey)
  return tonumber(type(itemKey) == "string" and itemKey:match("^i:(%d+):") or nil)
end

function Schema.IsVariantUnknown(itemKey)
  return type(itemKey) == "string" and itemKey:sub(-2) == ":?"
end

-- Parses the suffix id out of an item link or item string.
-- item:ID:enchant:gem1:gem2:gem3:gem4:suffixID:...
function Schema.SuffixFromLink(link)
  if type(link) ~= "string" then return nil end
  local itemString = link:match("item:([%-%d:]+)")
  if not itemString then return nil end
  local fields, index = {}, 0
  for value in (itemString .. ":"):gmatch("([^:]*):") do
    index = index + 1
    fields[index] = value
  end
  if not tonumber(fields[1]) then return nil end
  return tonumber(fields[7]) or 0, tonumber(fields[1])
end

-- Listing. raw: { marketKey, itemKey, quantity, buyoutTotal?, unitPrice?,
--   bid?, divisible, auctionID?, seen, source, scanId?, index? }
-- divisible listings carry an exact unitPrice; indivisible ones a total.
-- Returns listing or nil, reason. A listing without buyout is kept as
-- observable but never purchasable (buyable = false).
function Schema.NewListing(raw)
  if type(raw) ~= "table" then return nil, "not_table" end
  if type(raw.itemKey) ~= "string" then return nil, "item_key" end
  if type(raw.marketKey) ~= "string" then return nil, "market_key" end
  if not Money.IsQuantity(raw.quantity) then return nil, "quantity" end
  local listing = {
    marketKey = raw.marketKey,
    itemKey = raw.itemKey,
    quantity = raw.quantity,
    divisible = raw.divisible == true,
    auctionID = raw.auctionID,
    seen = raw.seen,
    source = raw.source,
    scanId = raw.scanId,
    complete = raw.complete ~= false,
    own = raw.own == true or nil,
  }
  listing.id = raw.auctionID or ((raw.scanId or "?") .. ":" .. tostring(raw.index or "?"))
  if raw.bid ~= nil then listing.bid = Money.Normalize(raw.bid) end
  if listing.divisible then
    local unit = Money.Normalize(raw.unitPrice)
    if unit and unit > 0 then
      listing.unitPrice = unit
      listing.buyoutTotal = Money.Mul(unit, raw.quantity)
    end
  else
    local total = Money.Normalize(raw.buyoutTotal)
    if total and total > 0 then
      listing.buyoutTotal = total
      -- Derived and rounded up: a purchase price, not exact arithmetic.
      listing.unitPrice = Money.DivCeil(total, raw.quantity)
    end
  end
  -- Own auctions are observed but never bought nor used as a reference.
  listing.buyable = listing.buyoutTotal ~= nil and listing.complete and not listing.own
  return listing
end

-- Snapshot header. Scans are not atomic: counts and coverage are explicit.
function Schema.NewSnapshot(fields)
  return {
    id = fields.id,
    marketKey = fields.marketKey,
    mode = fields.mode, -- "replicate" | "observed_search" | "watchlist"
    scope = fields.scope,
    build = fields.build,
    started = fields.started,
    finished = nil,
    status = "running",
    coverage = "unknown", -- "full_verified" | "full_unverified" | "partial"
    counts = { rows = 0, valid = 0, discarded = 0, incomplete = 0, itemKeys = 0, units = 0 },
    discardReasons = {},
  }
end
