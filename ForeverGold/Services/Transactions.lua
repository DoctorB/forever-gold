-- TransactionController: prepares a purchase summary and revalidates it
-- against fresh listings. It never spends: there is no code path from here,
-- or from any scan timer or event, to a buy, bid, post or cancel call.
-- Any change in price or quantity invalidates the previous preparation.
local _, ns = ...

local Transactions = {}
ns.Services.Transactions = Transactions

Transactions.VALID_SECONDS = 60

function Transactions.New(clock)
  return setmetatable({ clock = clock, prepared = nil }, { __index = Transactions })
end

-- Summary of what the user would do by hand. No spending.
function Transactions:Prepare(opportunity)
  local lots, total = {}, 0
  for _, lot in ipairs(opportunity.lots or {}) do
    local listing = lot.listing
    lots[#lots + 1] = {
      auctionID = listing.auctionID, quantity = lot.quantity, cost = lot.cost,
      unitPrice = listing.unitPrice, buyoutTotal = listing.buyoutTotal, divisible = listing.divisible,
    }
    total = total + lot.cost
  end
  self.prepared = {
    itemKey = opportunity.itemKey, strategy = opportunity.strategy, lots = lots, total = total,
    createdAt = self.clock(), status = "needs_refresh",
  }
  return self.prepared
end

-- Compares a preparation with fresh listings for the same item.
-- Returns status ("valid" | "changed" | "expired"), reasons.
function Transactions:Revalidate(prepared, fresh)
  local reasons = {}
  if not prepared then return "changed", { "nothing_prepared" } end
  if self.clock() - prepared.createdAt > Transactions.VALID_SECONDS then
    prepared.status = "expired"
    return "expired", { "too_old" }
  end
  local byId, used = {}, {}
  for _, listing in ipairs(fresh or {}) do
    if listing.auctionID ~= nil and listing.buyable then byId[listing.auctionID] = listing end
  end
  -- Lots without an auction id (replicate rows) match an unused fresh lot
  -- with the same quantity and total; anything else counts as changed.
  local function sameLot(lot)
    for index, listing in ipairs(fresh or {}) do
      if not used[index] and listing.buyable and not listing.divisible
        and listing.quantity == lot.quantity and listing.buyoutTotal == lot.buyoutTotal then
        used[index] = true
        return listing
      end
    end
    return nil
  end
  for _, lot in ipairs(prepared.lots) do
    local now
    if lot.auctionID ~= nil then
      now = byId[lot.auctionID]
    elseif not lot.divisible then
      now = sameLot(lot)
    end
    if not now then
      reasons[#reasons + 1] = "lot_missing"
    elseif lot.divisible then
      if now.unitPrice ~= lot.unitPrice then reasons[#reasons + 1] = "price_changed" end
      if now.quantity < lot.quantity then reasons[#reasons + 1] = "quantity_changed" end
    else
      if now.buyoutTotal ~= lot.buyoutTotal then reasons[#reasons + 1] = "price_changed" end
      if now.quantity ~= lot.quantity then reasons[#reasons + 1] = "quantity_changed" end
    end
  end
  prepared.status = #reasons == 0 and "valid" or "changed"
  return prepared.status, reasons
end

function Transactions:Invalidate(reason)
  if self.prepared then
    self.prepared.status = "invalidated"
    self.prepared.reason = reason
  end
end
