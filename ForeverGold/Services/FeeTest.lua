-- FeeTest: guided measurement of the AH deposit and fee with an item the
-- player chooses. ForeverGold never posts: the player posts the item from
-- the native AH window; this service only observes.
--   armed    deposits asked to the server for 12/24/48 h (read-only)
--   posted   bag count drops while armed: deposit paid = gold before - after
--   sold     seller invoices in the mailbox: sale price, refunded deposit and
--            the AH cut ("consignment") -> fee measured
-- State is saved (ForeverGoldDB.feeTest): the sale may come hours later.
-- No buyer name is stored.
local _, ns = ...

local Money = ns.Economy.Money
local Capabilities = ns.Core.Capabilities
local FeeTest = {}
ns.Services.FeeTest = FeeTest

FeeTest.DEFAULT_ITEM = 2840 -- Copper Bar
FeeTest.DURATIONS = { 1, 2, 3 } -- 12, 24, 48 hours in the AH UI

-- deps: { client, ah, items, opportunities, store, clock, printer?(kind, data) }
function FeeTest.New(deps)
  return setmetatable(deps, { __index = FeeTest })
end

function FeeTest:State()
  return self.store.db.feeTest
end

local function emit(self, kind, data)
  if self.printer then self.printer(kind, data) end
end

-- Lowest unit price seen in the last scan for the item, or nil.
function FeeTest:LowestPrice(itemID)
  local lowest
  for itemKey, view in pairs(self.opportunities.latest or {}) do
    if ns.Data.Schema.ItemIDOf(itemKey) == itemID then
      for _, listing in ipairs(view.listings) do
        local unit = listing.buyoutTotal and math.floor(listing.buyoutTotal / listing.quantity)
        if unit and listing.buyable and (not lowest or unit < lowest) then lowest = unit end
      end
    end
  end
  return lowest
end

local function deposits(self, itemID, quantity)
  local list = {}
  for _, duration in ipairs(FeeTest.DURATIONS) do
    list[duration] = self.ah:CommodityDeposit(itemID, duration, quantity) or self.ah:ItemDeposit(itemID, duration, quantity)
  end
  return list
end

-- Arms the test. Returns ok, reason.
function FeeTest:Start(itemID)
  itemID = itemID or FeeTest.DEFAULT_ITEM
  if not self.ah:IsOpen() then return false, "ah_closed" end
  local count = self.client:ItemCount(itemID)
  if not count or count < 1 then return false, "no_item" end
  local money = self.client:Money()
  if not money then return false, "money_unknown" end
  local info = self.items and self.items:Read(itemID)
  local state = {
    stage = "armed", itemID = itemID, name = info and info.name or tostring(itemID), count = count, money = money,
    deposits = deposits(self, itemID, count), lowest = self:LowestPrice(itemID), at = self.clock(), sales = {},
    seen = {},
  }
  self.store.db.feeTest = state
  emit(self, "armed", state)
  return true
end

function FeeTest:Cancel()
  self.store.db.feeTest = nil
  emit(self, "cancelled", nil)
end

-- Bag or money changes: detects the posting while armed.
function FeeTest:OnBagsOrMoney()
  local state = self:State()
  if not state or state.stage ~= "armed" then return end
  local count = self.client:ItemCount(state.itemID)
  local money = self.client:Money()
  if not count or not money then return end
  local posted = state.count - count
  local paid = state.money - money
  -- Only a drop of items with gold going out, at the open AH, is a posting;
  -- anything else (a merchant sale, a purchase) just moves the baseline.
  if posted <= 0 or paid <= 0 or not self.ah:IsOpen() then
    if posted ~= 0 or paid ~= 0 then state.count, state.money = count, money end
    return
  end
  -- Quote again for the quantity actually posted (the baseline may have moved).
  local calc = deposits(self, state.itemID, posted)
  local duration
  for _, d in ipairs(FeeTest.DURATIONS) do
    if calc[d] and calc[d] == paid then duration = d end
  end
  state.stage = "posted"
  state.posted = { at = self.clock(), quantity = posted, deposit = paid, calculated = calc, duration = duration }
  if duration and not Capabilities.IsVerified("deposit") then
    local evidence = { t = self.clock(), itemID = state.itemID, quantity = posted, deposit = paid, duration = duration }
    self.store.db.verifiedRuntime.deposit = evidence
    Capabilities.RecordRuntime("deposit", evidence)
    state.posted.verifiedNow = true
  end
  self.ah:QueryOwned()
  emit(self, "posted", state)
end

-- Own auctions listed: keeps the posted unit price for the report.
function FeeTest:OnOwnedAuctions()
  local state = self:State()
  if not state or not state.posted or state.posted.buyout then return end
  for _, auction in ipairs(self.ah:ReadOwned()) do
    if auction.itemID == state.itemID then
      state.posted.buyout, state.posted.ownedQuantity = auction.buyoutAmount, auction.quantity
      emit(self, "owned", state)
      return
    end
  end
end

-- Mailbox contents: reads the seller invoices of the test item.
function FeeTest:OnInbox()
  local state = self:State()
  if not state or (state.stage ~= "posted" and state.stage ~= "sold") then return end
  local found = 0
  for _, invoice in ipairs(self.client:SellerInvoices()) do
    if invoice.itemName == state.name then
      local signature = table.concat({ tostring(invoice.subject), tostring(invoice.money), tostring(invoice.bid),
        tostring(invoice.consignment), tostring(invoice.daysLeft) }, "|")
      if not state.seen[signature] then
        state.seen[signature] = true
        local price = (invoice.bid and invoice.bid > 0) and invoice.bid or invoice.buyout
        state.sales[#state.sales + 1] = {
          price = price, deposit = invoice.deposit, consignment = invoice.consignment, money = invoice.money,
          count = invoice.count,
        }
        found = found + 1
      end
    end
  end
  if found == 0 then return end
  local price, cut = 0, 0
  for _, sale in ipairs(state.sales) do
    if Money.IsCopper(sale.price) and Money.IsCopper(sale.consignment) then
      price, cut = price + sale.price, cut + sale.consignment
    end
  end
  state.stage = "sold"
  if price > 0 then
    local feeBp = math.floor(cut * Money.BP / price + 0.5)
    state.result = { feeBp = feeBp, price = price, cut = cut, sales = #state.sales }
    local settings = self.store:Settings()
    settings.feeBp, settings.feeVerified = feeBp, true
    local evidence = { t = self.clock(), feeBp = feeBp, price = price, cut = cut, sales = #state.sales }
    self.store.db.verifiedRuntime.fee = evidence
    Capabilities.RecordRuntime("fee", evidence)
  end
  emit(self, "sold", state)
end
