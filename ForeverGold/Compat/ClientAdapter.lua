-- ClientAdapter: the only place that touches general client globals.
-- Everything goes through `env` (the global table in game, a fake offline)
-- and every probe is non-destructive: presence checks and plain getters only.
local _, ns = ...

local ClientAdapter = {}
ns.Compat.ClientAdapter = ClientAdapter

-- Symbols audited by /fg diagnostics (spec 3, investigation matrix).
-- { capability id, namespace or nil, function name }
ClientAdapter.SYMBOLS = {
  { "GetBuildInfo", nil, "GetBuildInfo" },
  { "C_AuctionHouse.ReplicateItems", "C_AuctionHouse", "ReplicateItems" },
  { "C_AuctionHouse.GetNumReplicateItems", "C_AuctionHouse", "GetNumReplicateItems" },
  { "C_AuctionHouse.GetReplicateItemInfo", "C_AuctionHouse", "GetReplicateItemInfo" },
  { "C_AuctionHouse.GetReplicateItemLink", "C_AuctionHouse", "GetReplicateItemLink" },
  { "C_AuctionHouse.SendSearchQuery", "C_AuctionHouse", "SendSearchQuery" },
  { "C_AuctionHouse.GetItemSearchResultInfo", "C_AuctionHouse", "GetItemSearchResultInfo" },
  { "C_AuctionHouse.GetNumItemSearchResults", "C_AuctionHouse", "GetNumItemSearchResults" },
  { "C_AuctionHouse.HasFullItemSearchResults", "C_AuctionHouse", "HasFullItemSearchResults" },
  { "C_AuctionHouse.GetCommoditySearchResultInfo", "C_AuctionHouse", "GetCommoditySearchResultInfo" },
  { "C_AuctionHouse.GetNumCommoditySearchResults", "C_AuctionHouse", "GetNumCommoditySearchResults" },
  { "C_AuctionHouse.HasFullCommoditySearchResults", "C_AuctionHouse", "HasFullCommoditySearchResults" },
  { "C_AuctionHouse.IsThrottledMessageSystemReady", "C_AuctionHouse", "IsThrottledMessageSystemReady" },
  { "C_AuctionHouse.MakeItemKey", "C_AuctionHouse", "MakeItemKey" },
  { "C_AuctionHouse.SupportsCopperValues", "C_AuctionHouse", "SupportsCopperValues" },
  { "C_AuctionHouse.GetItemKeyInfo", "C_AuctionHouse", "GetItemKeyInfo" },
  { "C_AuctionHouse.GetQuoteDurationRemaining", "C_AuctionHouse", "GetQuoteDurationRemaining" },
  { "C_AuctionHouse.CancelCommoditiesPurchase", "C_AuctionHouse", "CancelCommoditiesPurchase" },
  { "C_AuctionHouse.PlaceBid", "C_AuctionHouse", "PlaceBid" },
  { "C_AuctionHouse.StartCommoditiesPurchase", "C_AuctionHouse", "StartCommoditiesPurchase" },
  { "C_AuctionHouse.ConfirmCommoditiesPurchase", "C_AuctionHouse", "ConfirmCommoditiesPurchase" },
  { "C_AuctionHouse.CalculateItemDeposit", "C_AuctionHouse", "CalculateItemDeposit" },
  { "C_AuctionHouse.CalculateCommodityDeposit", "C_AuctionHouse", "CalculateCommodityDeposit" },
  { "C_Item.GetItemInfo", "C_Item", "GetItemInfo" },
  { "C_Item.RequestLoadItemDataByID", "C_Item", "RequestLoadItemDataByID" },
  { "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI", "GetRecipeInfo" },
  { "C_TradeSkillUI.GetRecipeSchematic", "C_TradeSkillUI", "GetRecipeSchematic" },
  { "C_EventUtils.IsEventValid", "C_EventUtils", "IsEventValid" },
  { "issecretvalue", nil, "issecretvalue" },
  { "GetMoney", nil, "GetMoney" },
  { "GetItemCount", nil, "GetItemCount" },
}

-- Candidate events (spec 3); registered only when the client validates them.
ClientAdapter.EVENTS = {
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
  "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "GET_ITEM_INFO_RECEIVED", "ITEM_KEY_ITEM_INFO_RECEIVED",
  "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
  "COMMODITY_PURCHASE_FAILED", "COMMODITY_PURCHASED", "ITEM_PURCHASED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "AUCTION_HOUSE_SHOW_ERROR", "MERCHANT_SHOW", "MERCHANT_CLOSED",
}

function ClientAdapter.New(env)
  return setmetatable({ env = env or _G }, { __index = ClientAdapter })
end

-- Function from env, or nil. Never calls it.
function ClientAdapter:Lookup(namespace, name)
  local env = self.env
  if namespace then
    local space = env[namespace]
    if type(space) ~= "table" then return nil end
    local fn = space[name]
    return type(fn) == "function" and fn or nil
  end
  local fn = env[name]
  return type(fn) == "function" and fn or nil
end

-- Calls an existing function in protected mode. Returns ok, results...
function ClientAdapter:Call(namespace, name, ...)
  local fn = self:Lookup(namespace, name)
  if not fn then return false, "missing" end
  return pcall(fn, ...)
end

function ClientAdapter:IsSecret(value)
  local check = self:Lookup(nil, "issecretvalue")
  if not check then return false end
  local ok, result = pcall(check, value)
  return (not ok) or result == true
end

-- { version, build, date, interface, projectID }
function ClientAdapter:BuildInfo()
  local info = {}
  local ok, version, build, date, interface = self:Call(nil, "GetBuildInfo")
  if ok then
    info.version, info.build, info.date, info.interface = version, build, date, interface
  end
  if type(self.env.WOW_PROJECT_ID) == "number" then info.projectID = self.env.WOW_PROJECT_ID end
  return info
end

-- Fields for Schema.MarketKey. Unknown values stay nil (own partition).
function ClientAdapter:MarketFields()
  local fields = {}
  local info = self:BuildInfo()
  fields.product = info.projectID and ("p" .. info.projectID) or nil
  local ok, region = self:Call(nil, "GetCurrentRegion")
  if ok and type(region) == "number" then fields.region = region end
  local okRealm, realm = self:Call(nil, "GetNormalizedRealmName")
  if not (okRealm and type(realm) == "string" and realm ~= "") then
    okRealm, realm = self:Call(nil, "GetRealmName")
  end
  if okRealm and type(realm) == "string" and realm ~= "" then fields.realm = realm end
  local okFaction, faction = self:Call(nil, "UnitFactionGroup", "player")
  if okFaction and type(faction) == "string" then fields.faction = faction end
  return fields
end

-- Fills a Capabilities registry with presence checks (no side effects).
function ClientAdapter:Detect(capabilities)
  for _, symbol in ipairs(ClientAdapter.SYMBOLS) do
    local id, namespace, name = symbol[1], symbol[2], symbol[3]
    if self:Lookup(namespace, name) then
      capabilities:Set(id, "present")
    else
      capabilities:Set(id, "unsupported", "symbol not found")
    end
  end
  return capabilities
end

-- Whether the client recognises an event; nil when it cannot tell.
function ClientAdapter:IsEventValid(event)
  local ok, valid = self:Call("C_EventUtils", "IsEventValid", event)
  if ok then return valid == true end
  return nil
end

-- Registers events on a frame, skipping the ones the client rejects.
-- Returns registered, rejected (lists).
function ClientAdapter:RegisterEvents(frame, events)
  local registered, rejected = {}, {}
  for _, event in ipairs(events) do
    local valid = self:IsEventValid(event)
    if valid == false then
      rejected[#rejected + 1] = event
    else
      local ok = pcall(frame.RegisterEvent, frame, event)
      if ok then registered[#registered + 1] = event else rejected[#rejected + 1] = event end
    end
  end
  return registered, rejected
end

-- "20/10 14:00" for a timestamp, or "" when the client offers no date().
function ClientAdapter:FormatTime(t)
  if type(t) ~= "number" then return "" end
  local ok, text = self:Call(nil, "date", "%d/%m %H:%M", t)
  if ok and type(text) == "string" then return text end
  return ""
end

-- Player money in copper, or nil.
function ClientAdapter:Money()
  local ok, money = self:Call(nil, "GetMoney")
  if ok and type(money) == "number" and not self:IsSecret(money) then return money end
  return nil
end

-- Count of an item in the bags, or nil.
function ClientAdapter:ItemCount(itemID)
  local ok, count = self:Call(nil, "GetItemCount", itemID)
  if not ok then ok, count = self:Call("C_Item", "GetItemCount", itemID) end
  if ok and type(count) == "number" and not self:IsSecret(count) then return count end
  return nil
end

-- Clock and timer environment for Core/Scheduler.
function ClientAdapter:SchedulerEnv()
  local env = self.env
  return {
    now = function() return env.time and env.time() or 0 end,
    preciseMs = function()
      if env.debugprofilestop then return env.debugprofilestop() end
      return (env.GetTime and env.GetTime() or 0) * 1000
    end,
    after = function(delay, fn)
      if env.C_Timer and env.C_Timer.After then env.C_Timer.After(delay, fn) end
    end,
    random = function() return env.math and env.math.random and env.math.random() or 0.5 end,
  }
end
