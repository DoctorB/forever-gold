-- DepositCheck: compares the AH deposit the client quotes for items in the
-- bags with the formula in Economy/Deposit, so the estimate used for every
-- item can be trusted. Runs once per AH visit, a few items at a time, and
-- only asks for quotes: CalculateItemDeposit / CalculateCommodityDeposit do
-- not post anything. Bound items (cannot be sold on the AH) are skipped.
-- Evidence in ForeverGoldDB.depositChecks: { samples = {...}, items = {
-- [itemID] = "match" | "mismatch" } }.
local _, ns = ...

local Deposit = ns.Economy.Deposit
local DepositCheck = {}
ns.Services.DepositCheck = DepositCheck

DepositCheck.DELAY = 2 -- seconds after the AH opens
DepositCheck.MAX_ITEMS = 8 -- new items checked per visit
DepositCheck.KEEP = 60 -- samples kept
DepositCheck.VERIFY_ITEMS = 5 -- matching items needed, with no mismatch
DepositCheck.BAGS = { 0, 1, 2, 3, 4 }

-- deps: { client, ah, items, scheduler, clock, memory (persisted), trace?, bus? }
function DepositCheck.New(deps)
  local self = setmetatable(deps, { __index = DepositCheck })
  self.memory.samples = self.memory.samples or {}
  self.memory.items = self.memory.items or {}
  return self
end

function DepositCheck:OnShow()
  self.scheduler:Invalidate()
  self.scheduler:After(DepositCheck.DELAY, function()
    if self.ah:IsOpen() then self:Run() end
  end)
end

local function plainNumber(client, value)
  if client:IsSecret(value) or type(value) ~= "number" then return nil end
  return value
end

-- Bag slots: { bag, slot, itemID, count, bound }.
function DepositCheck:Slots()
  local c, slots = self.client, {}
  for _, bag in ipairs(DepositCheck.BAGS) do
    local ok, count = c:Call("C_Container", "GetContainerNumSlots", bag)
    if not ok then ok, count = c:Call(nil, "GetContainerNumSlots", bag) end
    for slot = 1, (ok and type(count) == "number") and count or 0 do
      local okInfo, info = c:Call("C_Container", "GetContainerItemInfo", bag, slot)
      if okInfo and type(info) == "table" and type(info.itemID) == "number" then
        slots[#slots + 1] = { bag = bag, slot = slot, itemID = info.itemID, count = plainNumber(c, info.stackCount) or 1,
          bound = info.isBound == true }
      end
    end
  end
  return slots
end

-- Server quote for one duration, or nil.
function DepositCheck:Quote(slot, commodity, duration, quantity)
  local c = self.client
  if commodity then
    local ok, deposit = c:Call("C_AuctionHouse", "CalculateCommodityDeposit", slot.itemID, duration, quantity)
    return ok and plainNumber(c, deposit) or nil
  end
  local itemLocation = c.env and c.env.ItemLocation
  if type(itemLocation) ~= "table" then return nil end
  local okLoc, location = c:Call("ItemLocation", "CreateFromBagAndSlot", itemLocation, slot.bag, slot.slot)
  if not okLoc or location == nil then return nil end
  local ok, deposit = c:Call("C_AuctionHouse", "CalculateItemDeposit", location, duration, quantity)
  return ok and plainNumber(c, deposit) or nil
end

-- Checks up to MAX_ITEMS items not checked before. Returns the samples added.
function DepositCheck:Run()
  local added, memory = {}, self.memory
  local seen = {}
  for _, slot in ipairs(self:Slots()) do
    if #added >= DepositCheck.MAX_ITEMS then break end
    local itemID = slot.itemID
    if not slot.bound and not memory.items[itemID] and not seen[itemID] then
      seen[itemID] = true
      local info = self.items and self.items:Read(itemID)
      local sellPrice = info and info.sellPrice
      if sellPrice and sellPrice > 0 then
        local commodity = self.ah:IsCommodity(itemID) == true
        -- A commodity is quoted for the whole stack; other items one unit.
        local quantity = commodity and slot.count or 1
        local sample = { itemID = itemID, quantity = quantity, commodity = commodity, sellPrice = sellPrice,
          quotes = {}, formula = {}, at = self.clock() }
        local match, quoted = true, 0
        for duration = 1, #Deposit.RATES_BP do
          local quote = self:Quote(slot, commodity, duration, quantity)
          local formula = Deposit.Estimate(sellPrice, quantity, duration)
          sample.quotes[duration], sample.formula[duration] = quote, formula
          if quote then
            quoted = quoted + 1
            if quote ~= formula then match = false end
          end
        end
        if quoted > 0 then
          sample.match = match
          memory.items[itemID] = match and "match" or "mismatch"
          memory.samples[#memory.samples + 1] = sample
          added[#added + 1] = sample
        end
      end
    end
  end
  while #memory.samples > DepositCheck.KEEP do table.remove(memory.samples, 1) end
  if self.trace and #added > 0 then
    local matches = 0
    for _, sample in ipairs(added) do if sample.match then matches = matches + 1 end end
    self.trace("deposit_check", { items = #added, matches = matches })
  end
  if self.bus and #added > 0 then self.bus:Publish("deposit.checked", self:Status()) end
  return added
end

-- { matched, mismatched, verified }.
function DepositCheck:Status()
  local matched, mismatched = 0, 0
  for _, result in pairs(self.memory.items) do
    if result == "match" then matched = matched + 1 else mismatched = mismatched + 1 end
  end
  return { matched = matched, mismatched = mismatched,
    verified = matched >= DepositCheck.VERIFY_ITEMS and mismatched == 0 }
end
