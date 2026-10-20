-- Purchases: assisted buying, one user click per purchase (spec 6 and 12).
--
--   planned -> quoting -> quoted --click--> confirming -> done
--   planned -> locating -> located --click--> confirming -> done
--   any step -> rejected | cancelled | failed ; confirming -> uncertain
--
-- Commodities: the server quotes the cheapest units (StartCommoditiesPurchase)
-- and the quote is accepted only if it does not exceed the planned total,
-- the spending cap and the player's money. Individual auctions: a read-only
-- search locates the auction and its buyout first. Confirm() is the only
-- spending step and is called only by UI/PurchasePanel from a button click;
-- an uncertain outcome is never retried automatically.
--
-- Bus: "purchase.state"(current)
local _, ns = ...

local Money = ns.Economy.Money
local Schema = ns.Data.Schema
local Purchases = {}
ns.Services.Purchases = Purchases

Purchases.QUOTE_TIMEOUT = 10
Purchases.CONFIRM_TIMEOUT = 20

Purchases.READY_TRIES = 15 -- seconds of waiting for the AH throttle before giving up

-- deps: { purchase (Compat/Purchase), client, scanner, scheduler, clock, bus, store, trace?(kind, data),
--         isReady?() -> true/false/nil (AH throttle system) }
function Purchases.New(deps)
  return setmetatable({
    purchase = deps.purchase, client = deps.client, scanner = deps.scanner, scheduler = deps.scheduler,
    clock = deps.clock, bus = deps.bus, store = deps.store, trace = deps.trace, isReady = deps.isReady, current = nil,
  }, { __index = Purchases })
end

-- Builds a purchase plan within budget = min(cap, money). Pure.
-- Returns plan or nil, reason.
function Purchases.Plan(opportunity, money, cap)
  if not Money.IsCopper(money) then return nil, "money_unknown" end
  local budget = money
  if Money.IsCopper(cap) and cap < budget then budget = cap end
  local itemID = opportunity.itemID or Schema.ItemIDOf(opportunity.itemKey)
  local plan = {
    itemKey = opportunity.itemKey, itemID = itemID, name = opportunity.name, strategy = opportunity.strategy,
    sellPrice = opportunity.sellPrice, budget = budget, quantity = 0, expectedTotal = 0, link = nil,
    -- A merchant pays the same for every variant of an item: for vendor
    -- purchases any variant will do; resale needs the exact one.
    anyVariant = opportunity.strategy == "vendor",
  }
  local lots = {}
  for _, lot in ipairs(opportunity.lots or {}) do lots[#lots + 1] = lot end
  table.sort(lots, function(a, b) return a.cost * b.quantity < b.cost * a.quantity end)
  if opportunity.commodity == true then
    plan.kind = "commodity"
    for _, lot in ipairs(lots) do
      local unit = lot.listing.unitPrice
      if not Money.IsCopper(unit) or unit <= 0 then break end
      local can = math.min(lot.quantity, math.floor((budget - plan.expectedTotal) / unit))
      if can <= 0 then break end
      plan.quantity = plan.quantity + can
      plan.expectedTotal = plan.expectedTotal + can * unit
      plan.unitMax = unit
      if can < lot.quantity then break end
    end
  else
    -- One individual auction per click: the cheapest lot that fits.
    plan.kind = "auction"
    for _, lot in ipairs(lots) do
      if lot.cost <= budget then
        plan.lot = { quantity = lot.quantity, buyoutTotal = lot.cost }
        -- Merged variants: the lot's own item key identifies the auction.
        if lot.listing and lot.listing.itemKey then plan.itemKey = lot.listing.itemKey end
        plan.link = lot.listing and lot.listing.link
        plan.quantity, plan.expectedTotal = lot.quantity, lot.cost
        break
      end
    end
  end
  if plan.quantity == 0 then return nil, "unaffordable" end
  if opportunity.strategy == "vendor" and Money.IsCopper(plan.sellPrice) then
    plan.expectedRevenue = plan.sellPrice * plan.quantity
  elseif opportunity.formula and Money.IsCopper(opportunity.formula.unitPrice) then
    plan.expectedRevenue = opportunity.formula.unitPrice * plan.quantity
  end
  if plan.expectedRevenue then plan.expectedProfit = plan.expectedRevenue - plan.expectedTotal end
  return plan
end

local function publish(self)
  if self.bus then self.bus:Publish("purchase.state", self.current) end
end

local function set(self, state, reason)
  local current = self.current
  current.state, current.reason = state, reason
  current.changed = self.clock()
  if self.trace then
    self.trace("purchase", { state = state, reason = reason, itemID = current.plan.itemID, kind = current.plan.kind,
      quantity = current.plan.quantity, expected = current.plan.expectedTotal })
  end
  publish(self)
end

-- Starts a new purchase for an opportunity (spends nothing).
function Purchases:Begin(opportunity, cap)
  if self.current and self.current.state == "confirming" then return nil, "busy" end
  self:Cancel("replaced")
  if not self.purchase:Supports(opportunity.commodity == true and "commodity" or "auction") then
    return nil, "unsupported"
  end
  local plan, reason = Purchases.Plan(opportunity, self.client:Money(), cap)
  if not plan then return nil, reason end
  self.current = { plan = plan, state = "planned", generation = self.scheduler:Invalidate() }
  publish(self)
  return self.current
end

local function alive(self, current, states)
  return self.current == current and states[current.state] == true
end

-- Step 2 (spends nothing): a quote for commodities, a read-only search for
-- individual auctions.
-- Step 2 entry point: waits (spending nothing) while the AH throttle system
-- is not ready, instead of failing; the request goes out once it is.
function Purchases:Prepare()
  local current = self.current
  if not current or (current.state ~= "planned" and current.state ~= "waiting") then return false, "not_planned" end
  if self.isReady and self.isReady() == false or (self.scanner and self.scanner:IsActive()) then
    current.waited = (current.waited or 0) + 1
    if current.waited > Purchases.READY_TRIES then
      set(self, "rejected", "throttled")
      return false, "throttled"
    end
    if current.state ~= "waiting" then set(self, "waiting") end
    self.scheduler:After(1, function()
      if alive(self, current, { waiting = true }) then self:Prepare() end
    end)
    return true
  end
  return self:Send(current)
end

-- The AH signals readiness: resume a waiting purchase at once.
function Purchases:OnReady()
  local current = self.current
  if current and current.state == "waiting" then self:Prepare() end
end

function Purchases:Send(current)
  local plan = current.plan
  if plan.kind == "commodity" then
    local ok, err = self.purchase:StartCommodity(plan.itemID, plan.quantity)
    if not ok then
      set(self, "failed", "request_failed:" .. tostring(err))
      return false, "request_failed"
    end
    set(self, "quoting")
    self.scheduler:After(Purchases.QUOTE_TIMEOUT, function()
      if alive(self, current, { quoting = true }) then set(self, "rejected", "no_quote") end
    end)
    return true
  end
  current.itemLevel = self.client.ItemLevel and self.client:ItemLevel(plan.link) or nil
  -- Variant items: build the server's key directly (bonus ID + offset).
  local _, _, bonus = Schema.VariantFromLink(plan.link)
  current.suffix = ns.Compat.AuctionHouse.SuffixForBonus(bonus)
  return self:Locate(current, nil)
end

-- Best auction in search results for the plan. For a merchant sale a lot
-- with more units at no higher price is never worse (the replicate and the
-- search may count a lot differently); resale needs the same lot.
local function matchLots(plan, listings)
  local best, matched, cheapest = nil, 0, nil
  for _, listing in ipairs(listings) do
    local sameItem = listing.itemKey == plan.itemKey
      or (plan.anyVariant and Schema.ItemIDOf(listing.itemKey) == plan.itemID)
    local enough = plan.anyVariant and listing.quantity >= plan.lot.quantity or listing.quantity == plan.lot.quantity
    if listing.buyoutTotal and (not cheapest or listing.buyoutTotal < cheapest) then cheapest = listing.buyoutTotal end
    if listing.buyable and listing.auctionID ~= nil and sameItem and enough
      and listing.buyoutTotal <= plan.lot.buyoutTotal then
      matched = matched + 1
      if not best or listing.buyoutTotal < best.buyoutTotal then best = listing end
    end
  end
  return best, matched, cheapest
end

-- Runs fn once the AH can take a request (spending nothing meanwhile).
function Purchases:WhenReady(current, fn, tries)
  tries = tries or 0
  if not (self.current == current and current.state == "locating") then return end
  if (self.isReady and self.isReady() == false) or (self.scanner and self.scanner:IsActive()) then
    if tries >= Purchases.READY_TRIES then
      set(self, "rejected", "throttled")
      return
    end
    self.scheduler:After(1, function() self:WhenReady(current, fn, tries + 1) end)
    return
  end
  fn()
end

local function keyText(key)
  return string.format("%s/%s/%s", tostring(key.itemLevel), tostring(key.itemSuffix), tostring(key.battlePetSpeciesID))
end

-- Locates the auction with a direct search (built key, or an exact key
-- from browse results). Steps are bounded and each has its own timeout.
function Purchases:Locate(current, key)
  local plan = current.plan
  current.step = (current.step or 0) + 1
  local step = current.step
  local suffix = current.suffix or Schema.SuffixOf(plan.itemKey)
  local ok, reason = self.scanner:Search(plan.itemID, suffix, function(_, listings)
    if not alive(self, current, { locating = true }) then return end
    local best, matched, cheapest = matchLots(plan, listings)
    if self.trace then
      self.trace("purchase_locate", { rows = #listings, matched = matched, cheapest = cheapest,
        wantQuantity = plan.lot.quantity, wantMax = plan.lot.buyoutTotal, planKey = plan.itemKey,
        level = current.itemLevel, suffix = suffix, key = key and keyText(key) or nil,
        firstKey = listings[1] and listings[1].itemKey, firstQuantity = listings[1] and listings[1].quantity })
    end
    if best then
      current.auction = { auctionID = best.auctionID, amount = best.buyoutTotal, quantity = best.quantity }
      set(self, "located")
    elseif current.browseKeys and #current.browseKeys > 0 then
      local nextKey = table.remove(current.browseKeys, 1)
      self:WhenReady(current, function() self:Locate(current, nextKey) end)
    elseif #listings == 0 and not current.browsed and plan.anyVariant and plan.name then
      -- No row at all: the built key does not reach this variant.
      self:WhenReady(current, function() self:BrowseFallback(current) end)
    else
      set(self, "rejected", "lot_gone")
    end
  end, current.itemLevel, key)
  if not ok then
    set(self, "rejected", reason)
    return false, reason
  end
  if current.state ~= "locating" then set(self, "locating") end
  -- A step may get no answer (or another search may replace it): stop
  -- waiting instead of leaving the panel on "waiting for the server".
  self.scheduler:After(Purchases.QUOTE_TIMEOUT + 2, function()
    if alive(self, current, { locating = true }) and current.step == step then set(self, "rejected", "no_answer") end
  end)
  return true
end

-- Variant items the direct search cannot find: browse by name like the
-- native AH window and try the server's own keys for this item (at most 5).
function Purchases:BrowseFallback(current)
  local plan = current.plan
  current.browsed = true
  current.step = (current.step or 0) + 1
  local step = current.step
  local ok = self.scanner:Browse(plan.name, function(results)
    if not alive(self, current, { locating = true }) then return end
    local keys, texts = {}, {}
    for _, result in ipairs(results) do
      if result.itemKey.itemID == plan.itemID and #keys < 5 then
        keys[#keys + 1] = result.itemKey
        texts[#texts + 1] = keyText(result.itemKey)
      end
    end
    if self.trace then
      self.trace("purchase_browse", { results = #results, sameItem = #keys, keys = table.concat(texts, ",") })
    end
    if #keys == 0 then
      set(self, "rejected", "lot_gone")
      return
    end
    current.browseKeys = keys
    local first = table.remove(current.browseKeys, 1)
    self:WhenReady(current, function() self:Locate(current, first) end)
  end)
  if not ok then
    set(self, "rejected", "lot_gone")
    return
  end
  self.scheduler:After(Purchases.QUOTE_TIMEOUT + 2, function()
    if alive(self, current, { locating = true }) and current.step == step then set(self, "rejected", "no_answer") end
  end)
end

-- Client events about quotes and purchases (from the AH adapter).
function Purchases:OnEvent(event, a, b)
  local current = self.current
  if not current then return end
  local plan = current.plan
  if event == "COMMODITY_PRICE_UPDATED" and current.state == "quoting" then
    local unit, total = Money.Normalize(a), Money.Normalize(b)
    current.quote = { unit = unit, total = total, at = self.clock() }
    local money = self.client:Money()
    if not total then
      set(self, "rejected", "quote_unreadable")
    elseif total > plan.expectedTotal then
      self.purchase:CancelCommodity()
      set(self, "rejected", "price_up")
    elseif total > plan.budget or (money and total > money) then
      self.purchase:CancelCommodity()
      set(self, "rejected", "unaffordable")
    else
      set(self, "quoted")
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" and current.state == "quoting" then
    set(self, "rejected", "unavailable")
  elseif current.state == "confirming" then
    if event == "COMMODITY_PURCHASE_SUCCEEDED" and plan.kind == "commodity" then
      self:Finish("done")
    elseif event == "COMMODITY_PURCHASE_FAILED" and plan.kind == "commodity" then
      set(self, "failed", "server_refused")
    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and current.auction and a == current.auction.auctionID then
      self:Finish("done")
    elseif event == "ITEM_PURCHASED" and plan.kind == "auction" and a == plan.itemID then
      self:Finish("done")
    elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
      set(self, "failed", "server_error")
    end
  end
end

-- Spending step. Called only from a button click (UI/PurchasePanel).
function Purchases:Confirm()
  local current = self.current
  if not current then return false, "nothing" end
  local plan = current.plan
  local money = self.client:Money()
  if plan.kind == "commodity" then
    if current.state ~= "quoted" then return false, "not_quoted" end
    local left = self.purchase:QuoteRemaining()
    if left ~= nil and left <= 0 then
      set(self, "rejected", "quote_expired")
      return false, "quote_expired"
    end
    if money and current.quote.total > money then
      set(self, "rejected", "unaffordable")
      return false, "unaffordable"
    end
    current.moneyBefore = money
    local ok = self.purchase:ConfirmCommodity(plan.itemID, plan.quantity)
    if not ok then
      set(self, "failed", "request_failed")
      return false, "request_failed"
    end
  else
    if current.state ~= "located" then return false, "not_located" end
    if money and current.auction.amount > money then
      set(self, "rejected", "unaffordable")
      return false, "unaffordable"
    end
    current.moneyBefore = money
    local ok = self.purchase:Buyout(current.auction.auctionID, current.auction.amount)
    if not ok then
      set(self, "failed", "request_failed")
      return false, "request_failed"
    end
  end
  set(self, "confirming")
  self.scheduler:After(Purchases.CONFIRM_TIMEOUT, function()
    -- No answer: the outcome is unknown. Never retried; recorded to verify.
    if alive(self, current, { confirming = true }) then self:Finish("uncertain") end
  end)
  return true
end

-- Records the outcome in the ledger (status done or uncertain).
function Purchases:Finish(status)
  local current = self.current
  local plan = current.plan
  local moneyAfter = self.client:Money()
  local expected = current.quote and current.quote.total or (current.auction and current.auction.amount) or plan.expectedTotal
  local paid = expected
  if status == "done" and current.moneyBefore and moneyAfter and current.moneyBefore - moneyAfter > 0 then
    paid = current.moneyBefore - moneyAfter
  end
  -- An auction may hold more units than planned (merchant sales accept it).
  if current.auction and current.auction.quantity and current.auction.quantity ~= plan.quantity then
    plan.quantity = current.auction.quantity
    if plan.sellPrice then plan.expectedRevenue = plan.sellPrice * plan.quantity end
  end
  local ledger = self.store.db.ledger
  ledger[#ledger + 1] = {
    t = self.clock(), kind = "purchase", status = status, strategy = plan.strategy, itemKey = plan.itemKey,
    itemID = plan.itemID, name = plan.name, quantity = plan.quantity, cost = paid, expected = expected,
    sellPrice = plan.sellPrice, remaining = plan.quantity, sold = 0, revenue = 0,
  }
  current.ledgerIndex = #ledger
  current.paid = paid
  set(self, status)
end

function Purchases:Cancel(reason)
  local current = self.current
  if not current then return end
  if current.state == "confirming" then
    self:Finish("uncertain")
    return
  end
  if current.plan.kind == "commodity" and (current.state == "quoting" or current.state == "quoted") then
    self.purchase:CancelCommodity()
  end
  if current.state == "planned" or current.state == "waiting" or current.state == "quoting" or current.state == "quoted"
    or current.state == "locating" or current.state == "located" then
    set(self, "cancelled", reason)
  end
end
