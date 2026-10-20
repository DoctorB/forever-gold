-- AuctionHouse adapter: read-only primitives over C_AuctionHouse plus client
-- event translation. It never buys, posts, bids or cancels; those symbols
-- are only checked for presence by diagnostics.
-- Seller names returned by the client are never read into our records.
--
-- Callbacks set by the scanner (all optional):
--   onShow(), onClose(), onReplicateUpdate(), onThrottleReady(), onThrottleDropped(),
--   onCommodityResults(itemID), onItemResults(itemKeyTable), onItemKeyInfo(itemID), onBrowseResults(),
--   onPurchase(event, ...) for quote and purchase outcome events
local _, ns = ...

local Capabilities = ns.Core.Capabilities
local AuctionHouse = {}
ns.Compat.AuctionHouse = AuctionHouse

function AuctionHouse.New(client)
  return setmetatable({ client = client, open = false, callbacks = {}, indexBase = nil, commodity = {} },
    { __index = AuctionHouse })
end

-- Client events about quotes and purchases, forwarded to onPurchase.
AuctionHouse.PURCHASE_EVENTS = {
  COMMODITY_PRICE_UPDATED = true, COMMODITY_PRICE_UNAVAILABLE = true, COMMODITY_PURCHASE_SUCCEEDED = true,
  COMMODITY_PURCHASE_FAILED = true, COMMODITY_PURCHASED = true, ITEM_PURCHASED = true,
  AUCTION_HOUSE_PURCHASE_COMPLETED = true, AUCTION_HOUSE_SHOW_ERROR = true,
}

function AuctionHouse:SetCallbacks(callbacks)
  self.callbacks = callbacks or {}
end

local function fire(self, name, ...)
  local fn = self.callbacks[name]
  if fn then fn(...) end
end

-- Client event entry point (wired by Core/Init through the event frame).
function AuctionHouse:OnEvent(event, ...)
  if event == "AUCTION_HOUSE_SHOW" then
    self.open = true
    fire(self, "onShow")
  elseif event == "AUCTION_HOUSE_CLOSED" then
    self.open = false
    fire(self, "onClose")
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    fire(self, "onReplicateUpdate")
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    local itemID = ...
    if not self.client:IsSecret(itemID) and type(itemID) == "number" then fire(self, "onCommodityResults", itemID) end
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    local itemKey = ...
    if type(itemKey) == "table" and not self.client:IsSecret(itemKey) then fire(self, "onItemResults", itemKey) end
  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    fire(self, "onThrottleReady")
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    fire(self, "onThrottleDropped")
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    fire(self, "onBrowseResults")
  elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
    local itemID = ...
    if type(itemID) == "number" and self.commodity[itemID] == "pending" then
      self.commodity[itemID] = nil
      fire(self, "onItemKeyInfo", itemID)
    end
  elseif AuctionHouse.PURCHASE_EVENTS[event] then
    fire(self, "onPurchase", event, ...)
  end
end

-- What this client offers to the scanner, with verification state.
function AuctionHouse:GetCapabilities()
  local c = self.client
  return {
    replicate = c:Lookup("C_AuctionHouse", "ReplicateItems") ~= nil
      and c:Lookup("C_AuctionHouse", "GetNumReplicateItems") ~= nil
      and c:Lookup("C_AuctionHouse", "GetReplicateItemInfo") ~= nil,
    commoditySearch = c:Lookup("C_AuctionHouse", "GetCommoditySearchResultInfo") ~= nil,
    itemSearch = c:Lookup("C_AuctionHouse", "GetItemSearchResultInfo") ~= nil,
    targetedSearch = c:Lookup("C_AuctionHouse", "SendSearchQuery") ~= nil
      and c:Lookup("C_AuctionHouse", "MakeItemKey") ~= nil,
    throttleCheck = c:Lookup("C_AuctionHouse", "IsThrottledMessageSystemReady") ~= nil,
    verified = Capabilities.VERIFIED,
  }
end

function AuctionHouse:IsOpen()
  return self.open
end

-- true/false, or nil when the client offers no readiness check.
function AuctionHouse:IsReady()
  local ok, ready = self.client:Call("C_AuctionHouse", "IsThrottledMessageSystemReady")
  if not ok then return nil end
  return ready == true
end

function AuctionHouse:RequestReplicate()
  local ok, err = self.client:Call("C_AuctionHouse", "ReplicateItems")
  return ok, err
end

function AuctionHouse:NumReplicate()
  local ok, count = self.client:Call("C_AuctionHouse", "GetNumReplicateItems")
  if ok and type(count) == "number" and not self.client:IsSecret(count) then return count end
  return nil
end

-- The reference documents the index as a plain number, not a luaIndex, so it
-- is probably 0-based; the row at index 0 decides. Cached per scan.
function AuctionHouse:DetectIndexBase(count)
  if not count or count <= 0 then return 0 end
  local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, itemID = self.client:Call("C_AuctionHouse", "GetReplicateItemInfo", 0)
  if ok and type(itemID) == "number" and itemID > 0 then return 0 end
  return 1
end

-- One replicate row as plain values. Owner and bidder names are discarded.
-- Returns row table or nil, reason.
function AuctionHouse:ReadReplicateRow(index)
  local c = self.client
  local ok, name, _, count, quality, _, level, _, minBid, _, buyout, bidAmount, _, _, _, _, saleStatus, itemID, hasAllInfo =
    c:Call("C_AuctionHouse", "GetReplicateItemInfo", index)
  if not ok then return nil, "call_failed" end
  if c:IsSecret(itemID) or c:IsSecret(count) or c:IsSecret(buyout) then return nil, "secret" end
  local row = {
    index = index, itemID = itemID, count = count, quality = quality, level = level,
    minBid = minBid, buyout = buyout, bidAmount = bidAmount, saleStatus = saleStatus,
    hasAllInfo = hasAllInfo == true, hasName = type(name) == "string",
  }
  local okLink, link = c:Call("C_AuctionHouse", "GetReplicateItemLink", index)
  if okLink and type(link) == "string" and not c:IsSecret(link) then row.link = link end
  return row
end

-- true/false from a HasFull* getter, nil when the client cannot tell.
function AuctionHouse:FullFlag(name, key)
  local ok, full = self.client:Call("C_AuctionHouse", name, key)
  if not ok then return nil end
  return full == true
end

-- Commodity search results for an itemID. Returns rows, full (bool or nil).
function AuctionHouse:ReadCommodityResults(itemID)
  local c = self.client
  local rows = {}
  local ok, count = c:Call("C_AuctionHouse", "GetNumCommoditySearchResults", itemID)
  if not ok or type(count) ~= "number" then return rows, nil end
  for index = 1, math.min(count, 500) do
    local okRow, info = c:Call("C_AuctionHouse", "GetCommoditySearchResultInfo", itemID, index)
    if okRow and type(info) == "table" then
      rows[#rows + 1] = {
        itemID = info.itemID, quantity = info.quantity, unitPrice = info.unitPrice, auctionID = info.auctionID,
        own = info.containsOwnerItem == true or (type(info.numOwnerItems) == "number" and info.numOwnerItems > 0),
      }
    end
  end
  return rows, self:FullFlag("HasFullCommoditySearchResults", itemID)
end

-- Item search results for a client ItemKey table. Returns rows, full.
function AuctionHouse:ReadItemResults(itemKey)
  local c = self.client
  local rows = {}
  local ok, count = c:Call("C_AuctionHouse", "GetNumItemSearchResults", itemKey)
  if not ok or type(count) ~= "number" then return rows, nil end
  for index = 1, math.min(count, 500) do
    local okRow, info = c:Call("C_AuctionHouse", "GetItemSearchResultInfo", itemKey, index)
    if okRow and type(info) == "table" then
      rows[#rows + 1] = {
        itemID = itemKey.itemID, suffix = itemKey.itemSuffix, quantity = info.quantity,
        buyout = info.buyoutAmount, minBid = info.minBid, auctionID = info.auctionID, link = info.itemLink,
        own = info.containsOwnerItem == true,
      }
    end
  end
  return rows, self:FullFlag("HasFullItemSearchResults", itemKey)
end

-- Targeted read-only search (used for quote refresh before an assisted
-- action). Returns ok, reason.
-- itemLevel: for items whose variant is a bonus ID (0 otherwise); key: an
-- exact client ItemKey (from browse results) that replaces the built one.
function AuctionHouse:SendSearch(itemID, suffix, itemLevel, key)
  local c = self.client
  if type(key) ~= "table" then
    local okKey
    okKey, key = c:Call("C_AuctionHouse", "MakeItemKey", itemID, itemLevel or 0, suffix or 0, 0)
    if not okKey or type(key) ~= "table" then return false, "item_key" end
  end
  local ok, err = c:Call("C_AuctionHouse", "SendSearchQuery", key, {}, true)
  if not ok then return false, tostring(err) end
  return true, key
end

-- Read-only browse by name, as the native AH window does; results arrive
-- with AUCTION_HOUSE_BROWSE_RESULTS_UPDATED and carry the server's exact keys.
function AuctionHouse:SendBrowse(name)
  local ok, err = self.client:Call("C_AuctionHouse", "SendBrowseQuery",
    { searchString = name, sorts = {}, filters = {}, itemClassFilters = {} })
  return ok, err
end

-- { { itemKey = table, totalQuantity, minPrice } }
function AuctionHouse:ReadBrowseResults()
  local ok, results = self.client:Call("C_AuctionHouse", "GetBrowseResults")
  if not ok or type(results) ~= "table" then return {} end
  local list = {}
  for _, result in ipairs(results) do
    if type(result) == "table" and type(result.itemKey) == "table" then
      list[#list + 1] = { itemKey = result.itemKey, totalQuantity = result.totalQuantity, minPrice = result.minPrice }
    end
  end
  return list
end

-- Whether an item trades as a commodity (partial purchase at a unit price):
-- true/false, or nil while the client loads the item key information
-- (ITEM_KEY_ITEM_INFO_RECEIVED then fires onItemKeyInfo). Cached.
function AuctionHouse:IsCommodity(itemID)
  local cached = self.commodity[itemID]
  if cached == true or cached == false then return cached end
  local c = self.client
  local okKey, key = c:Call("C_AuctionHouse", "MakeItemKey", itemID, 0, 0, 0)
  if not okKey or type(key) ~= "table" then return nil end
  local ok, info = c:Call("C_AuctionHouse", "GetItemKeyInfo", key)
  if ok and type(info) == "table" and type(info.isCommodity) == "boolean" then
    self.commodity[itemID] = info.isCommodity
    return info.isCommodity
  end
  if ok then self.commodity[itemID] = "pending" end
  return nil
end

-- Deposit for posting one item, or nil (needs the item in bags; optional).
function AuctionHouse:CommodityDeposit(itemID, duration, quantity)
  local ok, deposit = self.client:Call("C_AuctionHouse", "CalculateCommodityDeposit", itemID, duration, quantity)
  if ok and type(deposit) == "number" then return deposit end
  return nil
end
