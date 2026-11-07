-- Selling: what to put on the AH from the bags, and one auction per click.
-- Candidates are the items the character crafts (outputs of its known
-- recipes) whose best exit is the AH (Strategies/Crafting.Exits on the last
-- scan). Price: 1 copper under the lowest listing, never so low that a
-- merchant would pay more after the AH cut and the expected deposit loss.
-- Quantity: what the AH takes (Exits); the rest stays in the bags.
-- Posting (Compat/Post) happens only in PostNext, called from the Sell
-- tab's button: the client requires a click for each auction anyway.
-- Evidence in ForeverGoldDB.posts (last KEEP posts).
local _, ns = ...

local Money = ns.Economy.Money
local Deposit = ns.Economy.Deposit
local Selling = {}
ns.Services.Selling = Selling

Selling.UNDERCUT = 1 -- copper under the lowest listing
Selling.MAX_SCAN_AGE = 3600 -- seconds: older prices are not used to post
Selling.RESULT_WAIT = 10 -- seconds for the server's answer to a post
Selling.KEEP = 100

-- deps: { client, ah, items, post, scheduler, clock, store, slots(), market(itemID),
--   outputs() -> { [itemID] = recipe name }, scanAge() -> seconds or nil, trace?, bus? }
function Selling.New(deps)
  local self = setmetatable(deps, { __index = Selling })
  self.store.db.posts = self.store.db.posts or {}
  return self
end

local function bagCounts(slots)
  local counts, byItem = {}, {}
  for _, slot in ipairs(slots) do
    if not slot.bound then
      counts[slot.itemID] = (counts[slot.itemID] or 0) + slot.count
      local list = byItem[slot.itemID] or {}
      byItem[slot.itemID] = list
      list[#list + 1] = slot
    end
  end
  return counts, byItem
end

-- Unit price to post at and the lowest listing, or nil, reason.
function Selling.Price(market, sold, best)
  local _, _, lowest = ns.Strategies.Crafting.Liquidity(market)
  if lowest and lowest > Selling.UNDERCUT then return lowest - Selling.UNDERCUT, lowest end
  -- No listing: the estimate from the price history (exit "ah").
  local sellPrice = market.sellPrice or 0
  local auctionGross = best.gross - Money.Mul(sellPrice, best.vendorUnits or 0)
  if sold > 0 and auctionGross > 0 then return math.floor(auctionGross / sold), nil end
  return nil, "no_price"
end

-- The lots to post now: { lots = { lot }, skipped = { [reason] = n } }.
-- lot = { itemID, name, bags, quantity, unitPrice, lowest, deposit, net,
--   commodity, actions = { { bag, slot, quantity } } }.
function Selling:Plan()
  local result = { lots = {}, skipped = {} }
  local function skip(reason) result.skipped[reason] = (result.skipped[reason] or 0) + 1 end
  local settings = self.store:Settings()
  local counts, byItem = bagCounts(self.slots())
  local outputs = self.outputs()
  local ids = {}
  for itemID in pairs(counts) do if outputs[itemID] then ids[#ids + 1] = itemID end end
  table.sort(ids)
  for _, itemID in ipairs(ids) do
    local count = counts[itemID]
    local market = self.market(itemID)
    local best = market and ns.Strategies.Crafting.Exits(market, count, settings)
    if not best then
      skip("no_price")
    elseif best.exit == "vendor" then
      skip("merchant")
    else
      local sold = math.min(count, best.sold or count)
      local unitPrice, lowest = Selling.Price(market, sold, best)
      local commodity = self.ah:IsCommodity(itemID) == true
      local info = self.items and self.items:Read(itemID)
      local stack = (info and info.stackCount) or 1
      local actions, quantity = {}, 0
      if unitPrice then
        if commodity then
          -- One auction for all the units: the first stack's location.
          actions[1] = { bag = byItem[itemID][1].bag, slot = byItem[itemID][1].slot, quantity = sold }
          quantity = sold
        else
          for _, slot in ipairs(byItem[itemID]) do
            if quantity + slot.count <= sold then
              actions[#actions + 1] = { bag = slot.bag, slot = slot.slot, quantity = slot.count }
              quantity = quantity + slot.count
            end
          end
        end
      end
      if not unitPrice then
        skip(lowest or "no_price")
      elseif quantity == 0 then
        skip("demand")
      else
        local feeBp = settings.feeBp or 500
        local gross = Money.Mul(unitPrice, quantity)
        local net = ns.Economy.Costs.NetRevenue(gross, feeBp)
        local deposit = ns.Economy.Deposit.ForUnits(market.sellPrice or 0, quantity, commodity, nil, stack)
        local lossBp = settings.depositLossBp or ns.Strategies.Resale.DEFAULT_DEPOSIT_LOSS_BP
        local expected = (net or 0) - (Deposit.ExpectedLoss(deposit or 0, lossBp) or 0)
        local merchant = Money.Mul(market.sellPrice or 0, quantity)
        if expected <= merchant then
          skip("merchant")
        else
          result.lots[#result.lots + 1] = {
            itemID = itemID, name = (info and info.name) or outputs[itemID], bags = count, quantity = quantity,
            unitPrice = unitPrice, lowest = lowest, deposit = deposit, net = net, expected = expected,
            merchant = merchant, commodity = commodity, actions = actions,
          }
        end
      end
    end
  end
  table.sort(result.lots, function(a, b)
    if a.expected ~= b.expected then return a.expected > b.expected end
    return a.itemID < b.itemID
  end)
  self.plan = result
  return result
end

-- Why posting is not possible now, or nil.
function Selling:Blocked()
  if not self.post:Supports() then return "unsupported" end
  if not self.ah:IsOpen() then return "ah_closed" end
  if self.pending then return "waiting" end
  local age = self.scanAge()
  if not age or age > Selling.MAX_SCAN_AGE then return "scan_old" end
  return nil
end

-- The next auction to create (of `itemID` when given): lot, action; or nil.
function Selling:Next(itemID)
  local plan = self.plan or self:Plan()
  local lot = plan.lots[1]
  if itemID then
    lot = nil
    for _, candidate in ipairs(plan.lots) do if candidate.itemID == itemID then lot = candidate end end
  end
  if not lot then return nil end
  return lot, lot.actions[1]
end

-- Creates ONE auction (of `itemID` when given). Called only from a button
-- click (Sell tab, "To do" screen). Returns true, or false, reason.
function Selling:PostNext(itemID)
  local blocked = self:Blocked()
  if blocked then return false, blocked end
  self:Plan()
  local lot, action = self:Next(itemID)
  if not lot then return false, "nothing" end
  local okMoney, money = self.client:Call(nil, "GetMoney")
  local deposit = Deposit.ForUnits(self.market(lot.itemID).sellPrice or 0, action.quantity, lot.commodity, nil,
    lot.commodity and nil or action.quantity)
  if okMoney and type(money) == "number" and deposit and money < deposit then return false, "money" end
  local duration = Deposit.DEFAULT_DURATION
  local ok, err
  if lot.commodity then
    ok, err = self.post:Commodity(action.bag, action.slot, duration, action.quantity, lot.unitPrice)
  else
    ok, err = self.post:Item(action.bag, action.slot, duration, action.quantity, Money.Mul(lot.unitPrice, action.quantity))
  end
  local record = { t = self.clock(), itemID = lot.itemID, name = lot.name, quantity = action.quantity,
    unitPrice = lot.unitPrice, lowest = lot.lowest, duration = duration, deposit = deposit,
    commodity = lot.commodity, before = lot.bags }
  if not ok then
    record.result = "error"
    record.error = tostring(err):sub(1, 120)
    self:Record(record)
    return false, "post_failed"
  end
  record.result = "sent"
  self.pending = record
  self:Record(record)
  self.scheduler:After(Selling.RESULT_WAIT, function()
    if self.pending == record then self:Finish(record, self:BagsDropped(record) and "posted_bags" or "no_answer") end
  end)
  return true
end

function Selling:BagsDropped(record)
  local counts = bagCounts(self.slots())
  return (counts[record.itemID] or 0) <= record.before - record.quantity
end

function Selling:Record(record)
  local posts = self.store.db.posts
  posts[#posts + 1] = record
  while #posts > Selling.KEEP do table.remove(posts, 1) end
  if self.trace then
    self.trace("post", { itemID = record.itemID, quantity = record.quantity, unitPrice = record.unitPrice,
      commodity = record.commodity, result = record.result, error = record.error })
  end
end

function Selling:Finish(record, result)
  if self.pending ~= record then return end
  self.pending = nil
  record.result = result
  record.answeredAt = self.clock()
  if self.trace then self.trace("post_result", { itemID = record.itemID, result = result }) end
  self.plan = nil
  self.last = record
  if self.bus then self.bus:Publish("selling.updated", record) end
end

-- Client events: AUCTION_HOUSE_AUCTION_CREATED (auctionID),
-- AUCTION_HOUSE_POST_ERROR, AUCTION_HOUSE_POST_WARNING.
function Selling:OnEvent(event)
  local record = self.pending
  if not record then return end
  if event == "AUCTION_HOUSE_AUCTION_CREATED" then
    self:Finish(record, "posted")
  elseif event == "AUCTION_HOUSE_POST_ERROR" then
    self:Finish(record, "refused")
  elseif event == "AUCTION_HOUSE_POST_WARNING" then
    -- The client asks for a confirmation (e.g. a price far below the
    -- usual one): not given by the add-on, the auction is not created.
    self:Finish(record, "warning")
  end
end
