-- Post adapter: the ONLY file that calls client functions which create
-- auctions (enforced by tests/test_package.lua). It is driven exclusively by
-- Services/Selling, whose posting step is reached only from a button click
-- in the Sell tab (UI/Panels.lua): one click, one auction. No timer, event
-- or scan path leads here. Nothing is ever cancelled.
local _, ns = ...

local Post = {}
ns.Compat.Post = Post

function Post.New(client)
  return setmetatable({ client = client }, { __index = Post })
end

function Post:Supports()
  local c = self.client
  return c:Lookup("C_AuctionHouse", "PostCommodity") ~= nil and c:Lookup("C_AuctionHouse", "PostItem") ~= nil
    and type(c.env and c.env.ItemLocation) == "table"
end

local function location(client, bag, slot)
  local itemLocation = client.env and client.env.ItemLocation
  if type(itemLocation) ~= "table" then return nil end
  local ok, loc = client:Call("ItemLocation", "CreateFromBagAndSlot", itemLocation, bag, slot)
  if not ok or loc == nil then return nil end
  return loc
end

-- Creates a commodity auction: `quantity` units at `unitPrice` each.
function Post:Commodity(bag, slot, duration, quantity, unitPrice)
  local loc = location(self.client, bag, slot)
  if not loc then return false, "item_location" end
  return self.client:Call("C_AuctionHouse", "PostCommodity", loc, duration, quantity, unitPrice)
end

-- Creates an auction of the item in this slot, buyout only (no bid).
function Post:Item(bag, slot, duration, quantity, buyout)
  local loc = location(self.client, bag, slot)
  if not loc then return false, "item_location" end
  return self.client:Call("C_AuctionHouse", "PostItem", loc, duration, quantity, nil, buyout)
end
