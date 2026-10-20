-- AuctionHouse adapter: read-only primitives over C_AuctionHouse plus client
-- event translation. It never buys, posts, bids or cancels; those symbols
-- are only checked for presence by diagnostics.
-- Seller names returned by the client are never read into our records.
--
-- Callbacks set by the scanner (all optional):
--   onShow(), onClose(), onReplicateUpdate(), onThrottleReady(), onThrottleDropped(),
--   onCommodityResults(itemID), onItemResults(itemKeyTable)
local _, ns = ...

local Capabilities = ns.Core.Capabilities
local AuctionHouse = {}
ns.Compat.AuctionHouse = AuctionHouse

function AuctionHouse.New(client)
  return setmetatable({ client = client, open = false, callbacks = {}, indexBase = nil }, { __index = AuctionHouse })
end

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
function AuctionHouse:SendSearch(itemID, suffix)
  local c = self.client
  local okKey, key = c:Call("C_AuctionHouse", "MakeItemKey", itemID, 0, suffix or 0, 0)
  if not okKey or type(key) ~= "table" then return false, "item_key" end
  local ok, err = c:Call("C_AuctionHouse", "SendSearchQuery", key, {}, true)
  if not ok then return false, tostring(err) end
  return true, key
end

-- Deposit for posting one item, or nil (needs the item in bags; optional).
function AuctionHouse:CommodityDeposit(itemID, duration, quantity)
  local ok, deposit = self.client:Call("C_AuctionHouse", "CalculateCommodityDeposit", itemID, duration, quantity)
  if ok and type(deposit) == "number" then return deposit end
  return nil
end
