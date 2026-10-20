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

-- ItemKey from verified parts: "i:<itemID>:<suffix>" plus ":b<bonus ids>"
-- when the item string carries bonus IDs. On Forever (build 70450) random
-- variants such as "of the Bear" arrive as bonus IDs with an empty suffix
-- field, so bonus IDs are part of the key. variantUnknown when the source
-- could not expose the variant (e.g. missing link).
function Schema.ItemKey(itemID, suffix, variantUnknown, bonus)
  if type(itemID) ~= "number" or itemID <= 0 or math.floor(itemID) ~= itemID then return nil end
  if variantUnknown then return "i:" .. itemID .. ":?" end
  local key = "i:" .. itemID .. ":" .. (tonumber(suffix) or 0)
  if type(bonus) == "string" and bonus ~= "" then key = key .. ":b" .. bonus end
  return key
end

function Schema.ItemIDOf(itemKey)
  return tonumber(type(itemKey) == "string" and itemKey:match("^i:(%d+):") or nil)
end

function Schema.SuffixOf(itemKey)
  return tonumber(type(itemKey) == "string" and itemKey:match("^i:%d+:(%-?%d+)") or nil)
end

function Schema.IsItemKey(itemKey)
  return type(itemKey) == "string"
    and (itemKey:match("^i:%d+:%-?%d+$") ~= nil or itemKey:match("^i:%d+:%-?%d+:b[%d%.]+$") ~= nil)
end

function Schema.IsVariantUnknown(itemKey)
  return type(itemKey) == "string" and itemKey:sub(-2) == ":?"
end

-- Parses an item link or item string:
-- item:ID:enchant:gem1:gem2:gem3:gem4:suffixID:uniqueID:linkLevel:specID:
--      modifiersMask:itemContext:numBonusIDs:bonusID...:numModifiers:...
-- Returns itemID, suffix, bonus (sorted bonus IDs joined by "."), or nil.
function Schema.VariantFromLink(link)
  if type(link) ~= "string" then return nil end
  local itemString = link:match("item:([%-%d:]+)")
  if not itemString then return nil end
  local fields, index = {}, 0
  for value in (itemString .. ":"):gmatch("([^:]*):") do
    index = index + 1
    fields[index] = value
  end
  local itemID = tonumber(fields[1])
  if not itemID then return nil end
  local bonus = {}
  local count = tonumber(fields[13]) or 0
  for position = 14, 13 + math.min(count, 16) do
    local id = tonumber(fields[position])
    if id then bonus[#bonus + 1] = id end
  end
  table.sort(bonus)
  return itemID, tonumber(fields[7]) or 0, table.concat(bonus, ".")
end

-- Suffix id of a link (0 when empty); second value the itemID.
function Schema.SuffixFromLink(link)
  local itemID, suffix = Schema.VariantFromLink(link)
  if not itemID then return nil end
  return suffix, itemID
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
    samples = {}, -- evidence: multi-unit rows (itemID, count, buyout)
    links = {}, -- evidence: raw item strings
  }
end
