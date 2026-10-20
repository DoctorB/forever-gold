-- Purchase adapter: the ONLY file that calls client functions which spend
-- money (enforced by tests/test_package.lua). It is driven exclusively by
-- Services/Purchases, whose spending step is reached only from a button
-- click in UI/PurchasePanel. No timer, event or scan path leads here.
local _, ns = ...

local Purchase = {}
ns.Compat.Purchase = Purchase

function Purchase.New(client)
  return setmetatable({ client = client }, { __index = Purchase })
end

function Purchase:Supports(kind)
  local c = self.client
  if kind == "commodity" then
    return c:Lookup("C_AuctionHouse", "StartCommoditiesPurchase") ~= nil
      and c:Lookup("C_AuctionHouse", "ConfirmCommoditiesPurchase") ~= nil
  end
  return c:Lookup("C_AuctionHouse", "PlaceBid") ~= nil
end

-- Asks the server for a quote; the answer arrives as COMMODITY_PRICE_UPDATED
-- or COMMODITY_PRICE_UNAVAILABLE. Spends nothing.
function Purchase:StartCommodity(itemID, quantity)
  return self.client:Call("C_AuctionHouse", "StartCommoditiesPurchase", itemID, quantity)
end

-- Spends: buys the quoted commodity quantity.
function Purchase:ConfirmCommodity(itemID, quantity)
  return self.client:Call("C_AuctionHouse", "ConfirmCommoditiesPurchase", itemID, quantity)
end

function Purchase:CancelCommodity()
  return self.client:Call("C_AuctionHouse", "CancelCommoditiesPurchase")
end

-- Seconds left on the current commodity quote, or nil.
function Purchase:QuoteRemaining()
  local ok, seconds = self.client:Call("C_AuctionHouse", "GetQuoteDurationRemaining")
  if ok and type(seconds) == "number" then return seconds end
  return nil
end

-- Spends: buys one individual auction at its buyout.
function Purchase:Buyout(auctionID, amount)
  return self.client:Call("C_AuctionHouse", "PlaceBid", auctionID, amount)
end
