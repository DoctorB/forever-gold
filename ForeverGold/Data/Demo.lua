-- Demo fixture: fictional items and prices for the explicitly labelled DEMO
-- view. It lives in its own in-memory market and never touches real history.
local _, ns = ...

local Schema = ns.Data.Schema
local Demo = {}
ns.Data.Demo = Demo

Demo.MARKET = Schema.MarketKey({ product = "demo", region = "demo", realm = "demo", faction = "demo" })

local ITEMS = {
  [900001] = { name = "DEMO Linen Bundle", sellPrice = 50, classID = 7 },
  [900002] = { name = "DEMO Copper Bar", sellPrice = 10, classID = 7 },
  [900003] = { name = "DEMO Silk Thread", sellPrice = 25, classID = 7 },
  [900004] = { name = "DEMO Ring", sellPrice = 300, classID = 4 },
}

function Demo.Items()
  local provider = {}
  function provider.Read(_, itemID)
    local info = ITEMS[itemID]
    if not info then return nil end
    return { itemID = itemID, name = info.name, sellPrice = info.sellPrice, classID = info.classID }
  end
  function provider.Resolve(self, itemID, callback) callback(self:Read(itemID)) end
  return provider
end

local function lot(now, itemID, suffix, quantity, total, index, variantUnknown)
  return Schema.NewListing({
    marketKey = Demo.MARKET, itemKey = Schema.ItemKey(itemID, suffix, variantUnknown), quantity = quantity,
    buyoutTotal = total, divisible = false, seen = now, source = "demo", scanId = "demo", index = index,
  })
end

-- Seeds ten days of history and returns the current snapshot and listings.
function Demo.Build(now, history)
  local day = 86400
  for back = 10, 1, -1 do
    local t = now - back * day
    history:Record({ id = "demo-h" .. back, marketKey = Demo.MARKET, coverage = "full_unverified", finished = t }, {
      lot(t, 900002, 0, 100, 150000 + back * 1000, 1),
      lot(t, 900002, 0, 100, 160000, 2),
      lot(t, 900003, 0, 5, 900, 3),
    })
  end
  local snapshot = Schema.NewSnapshot({ id = "demo", marketKey = Demo.MARKET, mode = "demo", scope = "all", started = now })
  snapshot.finished, snapshot.coverage, snapshot.status = now, "partial", "partial"
  local listings = {
    lot(now, 900001, 0, 20, 700, 1), -- vendor: 20 x 50 = 1000 for 700
    lot(now, 900002, 0, 10, 6000, 2), -- resale candidate well below reference
    lot(now, 900002, 0, 10, 17000, 3),
    lot(now, 900003, 0, 5, 880, 4), -- near reference: no margin
    lot(now, 900004, 0, 1, 250, 5, true), -- suffix unknown: excluded from resale
  }
  return snapshot, listings
end
