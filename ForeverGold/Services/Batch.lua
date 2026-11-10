-- Batch ("Buy all"): walks the vendor offers one after another within a
-- total spending limit. It automates everything that spends nothing (plan,
-- quote, auction search, skipping offers that vanished) and stops at every
-- purchase: the game requires a click for each spending call, and so do the
-- spec and the add-on policy. The spending click is UI/PurchasePanel's batch
-- button, which calls Purchases:Confirm() directly.
--
-- Bus: "batch.state"(batch)
local _, ns = ...

local Money = ns.Economy.Money
local Batch = {}
ns.Services.Batch = Batch

-- Requests in a row without any answer before the run stops. Live 70790
-- (2026-11-06): once the server stopped answering, the run went on to send
-- 13 more requests that all went unanswered.
Batch.MAX_SILENT = 2
Batch.SILENT_REASONS = { no_answer = true, no_quote = true }

-- deps: { purchases, client, bus, clock, stale?() -> { [itemID] = true } }
function Batch.New(deps)
  return setmetatable({
    purchases = deps.purchases, client = deps.client, bus = deps.bus, clock = deps.clock, stale = deps.stale,
    active = false,
  }, { __index = Batch })
end

-- Vendor offers worth queueing, best first (prudent profit, then ROI);
-- offers a purchase attempt already found gone are left out.
function Batch.Queue(list, stale)
  local queue = {}
  for _, o in ipairs(list or {}) do
    if o.strategy == "vendor" and o.class ~= "speculative" and o.profit > 0 and not (stale and stale[o.itemID]) then
      queue[#queue + 1] = o
    end
  end
  -- Offers already there at the previous full scan first: fresh lots were
  -- mostly gone at the click (2026-11-08, 9 of 10).
  table.sort(queue, function(a, b)
    local pa, pb = (a.persisted or 0) > 0, (b.persisted or 0) > 0
    if pa ~= pb then return pa end
    if a.profit ~= b.profit then return a.profit > b.profit end
    return (a.roi or 0) > (b.roi or 0)
  end)
  return queue
end

local function publish(self)
  if self.bus then self.bus:Publish("batch.state", self) end
end

-- Starts a run over the given offers with a total cap (copper).
-- Returns ok, reason.
function Batch:Start(list, cap)
  if self.active then return false, "busy" end
  if not Money.IsCopper(cap) or cap <= 0 then return false, "no_cap" end
  local queue = Batch.Queue(list, self.stale and self.stale())
  if #queue == 0 then return false, "nothing" end
  self.active, self.queue, self.index, self.cap = true, queue, 0, cap
  self.spent, self.expected, self.bought, self.skipped = 0, 0, 0, 0
  self.ready, self.stopReason, self.silent = false, nil, 0
  self:Next()
  return true
end

-- Prepares the next affordable offer (spends nothing).
function Batch:Next()
  self.ready = false
  while self.active do
    self.index = self.index + 1
    local opportunity = self.queue[self.index]
    if not opportunity then
      self:Stop("done")
      return
    end
    local left = self.cap - self.spent
    if left <= 0 then
      self:Stop("cap")
      return
    end
    local stale = self.stale and self.stale()
    if not (stale and stale[opportunity.itemID]) then
      local started = self.purchases:Begin(opportunity, left)
      if started then
        self.current, self.purchase = opportunity, started
        publish(self)
        -- Any outcome, an immediate refusal included, arrives through
        -- OnPurchase, which moves on: this call must not move on again.
        self.purchases:Prepare()
        return
      end
    end
    self.skipped = self.skipped + 1
  end
end

-- Follows the purchase state machine (wired by Core/App).
function Batch:OnPurchase(current)
  -- Only the purchase this batch started counts (not one replaced by it).
  if not self.active or not current or current ~= self.purchase then return end
  local state = current.state
  if state == "rejected" and Batch.SILENT_REASONS[current.reason] then
    self.silent = (self.silent or 0) + 1
    if self.silent >= Batch.MAX_SILENT then
      self.skipped = self.skipped + 1
      self:Stop("server_silent")
      return
    end
  elseif state == "quoted" or state == "located" or state == "rejected" or state == "failed" then
    self.silent = 0 -- the server answered (a refusal is an answer too)
  end
  if state == "quoted" or state == "located" then
    self.ready = true
    self.amount = current.quote and current.quote.total or (current.auction and current.auction.amount)
    publish(self)
  elseif state == "confirming" then
    self.ready = false
    publish(self)
  elseif state == "done" then
    self.spent = self.spent + (current.paid or current.plan.expectedTotal)
    self.bought = self.bought + 1
    self.expected = self.expected + (current.plan.expectedRevenue or 0)
    self:Next()
  elseif state == "uncertain" then
    -- Unknown outcome: never continue spending blindly.
    self:Stop("uncertain")
  elseif state == "rejected" or state == "failed" then
    self.skipped = self.skipped + 1
    self:Next()
  elseif state == "cancelled" and current.reason ~= "replaced" then
    self:Stop("cancelled")
  end
end

function Batch:Stop(reason)
  if not self.active then return end
  self.active, self.ready, self.stopReason = false, false, reason
  if reason == "cancelled" or reason == "user" then self.purchases:Cancel("user") end
  publish(self)
end

function Batch:Cancel()
  self:Stop("user")
end
