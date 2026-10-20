-- Fakes for offline tests: manual clock and timers, a scriptable
-- C_AuctionHouse, a client environment and a minimal frame mock.
-- They reproduce our assumptions about the client, not the client itself.

Fakes = {}

-- Clock -------------------------------------------------------------------

function Fakes.Clock(start)
  local clock = { t = start or 1000000, ms = 0, timers = {}, msPerCall = 0.5, frames = 0 }
  function clock.now() return clock.t end
  function clock.preciseMs()
    clock.ms = clock.ms + clock.msPerCall
    return clock.ms
  end
  -- A zero delay means "next frame" (1/60 s), as with C_Timer.After(0, fn).
  function clock.after(delay, fn)
    if delay <= 0 then
      delay = 1 / 60
      clock.frames = clock.frames + 1
    end
    clock.timers[#clock.timers + 1] = { at = clock.t + delay, fn = fn, seq = #clock.timers }
  end
  function clock.random() return 0.5 end
  -- Advances time, running due timers in order (also ones they schedule).
  function clock.advance(seconds)
    local target = clock.t + (seconds or 0)
    while true do
      local index, best
      for i, timer in ipairs(clock.timers) do
        if timer.at <= target and (not best or timer.at < best.at) then index, best = i, timer end
      end
      if not best then break end
      table.remove(clock.timers, index)
      if best.at > clock.t then clock.t = best.at end
      best.fn()
    end
    clock.t = target
  end
  function clock.env() return { now = clock.now, preciseMs = clock.preciseMs, after = clock.after, random = clock.random } end
  return clock
end

-- C_AuctionHouse ----------------------------------------------------------

-- rows: { { itemID, count, buyout, minBid?, link?, hasAllInfo? } }, 0-based.
function Fakes.AuctionHouse(rows)
  local ah = {
    rows = rows or {}, delivered = false, ready = true, replicateCalls = 0, searchCalls = 0,
    spendCalls = 0, commodity = {}, items = {}, fullCommodity = true,
    commodityItems = {}, calls = {}, args = {},
  }
  local api = {}
  ah.api = api
  function api.ReplicateItems() ah.replicateCalls = ah.replicateCalls + 1 end
  function api.GetNumReplicateItems() return ah.delivered and #ah.rows or 0 end
  function api.GetReplicateItemInfo(index)
    local row = ah.delivered and ah.rows[index + 1]
    if not row then return nil, nil, 0, 0, nil, 0, nil, 0, 0, 0, 0, nil, nil, nil, nil, 0, 0, nil end
    local hasAll = row.hasAllInfo ~= false
    return hasAll and "Item" or nil, 1, row.count, 1, true, 1, "", row.minBid or 0, 1, row.buyout, 0,
      nil, nil, "SellerName", "SellerName-Realm", 0, row.itemID, hasAll
  end
  function api.GetReplicateItemLink(index)
    local row = ah.delivered and ah.rows[index + 1]
    if not row or row.hasAllInfo == false then return nil end
    return row.link or ("|cffffffff|Hitem:" .. row.itemID .. "::::::" .. (row.suffix or 0) .. ":::|h[Item]|h|r")
  end
  function api.IsThrottledMessageSystemReady() return ah.ready end
  function api.MakeItemKey(itemID, itemLevel, itemSuffix) return { itemID = itemID, itemLevel = itemLevel or 0, itemSuffix = itemSuffix or 0, battlePetSpeciesID = 0 } end
  function api.SendSearchQuery(itemKey) ah.searchCalls = ah.searchCalls + 1 ah.lastSearch = itemKey end
  function api.GetNumCommoditySearchResults(itemID) return #(ah.commodity[itemID] or {}) end
  function api.GetCommoditySearchResultInfo(itemID, index)
    local row = (ah.commodity[itemID] or {})[index]
    if not row then return nil end
    return { itemID = itemID, quantity = row.quantity, unitPrice = row.unitPrice, auctionID = row.auctionID,
      owners = { "Someone" }, totalNumberOfOwners = 1, numOwnerItems = row.own and 1 or 0, containsOwnerItem = row.own or false,
      containsAccountItem = false }
  end
  function api.HasFullCommoditySearchResults() return ah.fullCommodity end
  -- Item rows may carry a level: a key with another item level does not see them.
  local function itemRows(itemKey)
    local rows = {}
    for _, row in ipairs(ah.items[itemKey.itemID] or {}) do
      if (row.level or 0) == (itemKey.itemLevel or 0) then rows[#rows + 1] = row end
    end
    return rows
  end
  function api.GetNumItemSearchResults(itemKey) return #itemRows(itemKey) end
  function api.GetItemSearchResultInfo(itemKey, index)
    local row = itemRows(itemKey)[index]
    if not row then return nil end
    return { itemKey = itemKey, owners = {}, totalNumberOfOwners = 1, timeLeft = 1, auctionID = row.auctionID,
      quantity = row.quantity, buyoutAmount = row.buyout, containsOwnerItem = false, containsAccountItem = false,
      containsSocketedItem = false }
  end
  function api.HasFullItemSearchResults() return true end
  function api.SendBrowseQuery(query) ah.browseCalls = (ah.browseCalls or 0) + 1 ah.lastBrowse = query end
  function api.GetBrowseResults() return ah.browse or {} end
  function api.GetItemKeyInfo(itemKey)
    local status = ah.commodityItems[itemKey.itemID]
    if status == nil then return nil end
    return { itemID = itemKey.itemID, isCommodity = status }
  end
  function api.GetQuoteDurationRemaining() return ah.quoteLeft or 30 end
  function api.CalculateCommodityDeposit(itemID, duration, quantity)
    return ah.depositPerUnit and math.max(ah.minDeposit or 0, ah.depositPerUnit * quantity * duration) or nil
  end
  function api.QueryOwnedAuctions() ah.ownedQueries = (ah.ownedQueries or 0) + 1 end
  function api.GetOwnedAuctions() return ah.owned or {} end
  -- Purchase symbols exist (like the real client) and record every call;
  -- spendCalls counts only the calls that spend, post or cancel auctions.
  local spending = { PlaceBid = true, ConfirmCommoditiesPurchase = true, PostItem = true, PostCommodity = true,
    CancelAuction = true }
  for _, name in ipairs({ "PlaceBid", "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "CancelCommoditiesPurchase",
    "PostItem", "PostCommodity", "CancelAuction" }) do
    api[name] = function(...)
      ah.calls[name] = (ah.calls[name] or 0) + 1
      ah.args[name] = { ... }
      if spending[name] then ah.spendCalls = ah.spendCalls + 1 end
    end
  end
  return ah
end

-- Client environment --------------------------------------------------------

function Fakes.Env(clock, ah, extra)
  local env = {
    GetBuildInfo = function() return "1.60.1", "70450", "Oct 16 2026", 16001 end,
    WOW_PROJECT_ID = 18,
    GetCurrentRegion = function() return 3 end,
    GetNormalizedRealmName = function() return "ClassicBetaPvE" end,
    UnitFactionGroup = function() return "Alliance" end,
    C_AuctionHouse = ah and ah.api or nil,
    C_Item = {
      GetItemInfo = function(itemID)
        local info = extra and extra.items and extra.items[itemID]
        if not info then return nil end
        return info.name, "link", 1, 1, 1, "Type", "Sub", info.stackCount or 1, "", 1, info.sellPrice, info.classID or 7, 0, 0
      end,
      RequestLoadItemDataByID = function() end,
    },
    C_EventUtils = { IsEventValid = function(event) return not (extra and extra.invalidEvents and extra.invalidEvents[event]) end },
    C_Timer = { After = function(delay, fn) clock.after(delay, fn) end },
    time = function() return clock.t end,
    GetMoney = function() return extra and extra.wallet and extra.wallet.money or nil end,
    GetInboxNumItems = function() return #(extra and extra.inbox or {}) end,
    GetInboxHeaderInfo = function(index)
      local mail = extra.inbox[index]
      return nil, nil, "Auction House", mail.subject, mail.money, 0, 30
    end,
    GetInboxInvoiceInfo = function(index)
      local mail = extra.inbox[index]
      return mail.invoiceType, mail.itemName, "Buyer", mail.bid, mail.buyout, mail.deposit, mail.consignment
    end,
    GetItemCount = function(itemID) return extra and extra.bags and extra.bags[itemID] or 0 end,
    debugprofilestop = function() return clock.preciseMs() end,
    math = { random = function() return 0.5 end },
  }
  for key, value in pairs(extra and extra.globals or {}) do env[key] = value end
  return env
end

-- Builds an App on a fake env with the addon loaded offline.
function Fakes.App(options)
  options = options or {}
  local ns = options.ns or T.LoadAddon()
  local clock = options.clock or Fakes.Clock()
  local ah = options.ah or Fakes.AuctionHouse(options.rows)
  local env = Fakes.Env(clock, ah, options)
  local app = ns.Core.App.New(env)
  app.schedulerEnv = clock.env()
  app.clock = clock.now
  ns.app = app
  app:Load(options.saved)
  return app, ns, clock, ah, env
end

-- Frame mock ----------------------------------------------------------------

function Fakes.Frame(kind, name)
  local frame = {
    kind = kind, name = name, scripts = {}, events = {}, shown = true, text = "", width = 600, height = 300,
    checked = false, enabled = true,
  }
  local methods = {}
  function methods.SetScript(self, script, fn) self.scripts[script] = fn end
  function methods.GetScript(self, script) return self.scripts[script] end
  function methods.HookScript(self, script, fn) self.scripts[script] = fn end
  function methods.RegisterEvent(self, event) self.events[event] = true end
  function methods.UnregisterEvent(self, event) self.events[event] = nil end
  function methods.Show(self)
    self.shown = true
    if self.scripts.OnShow then self.scripts.OnShow(self) end
  end
  function methods.Hide(self) self.shown = false end
  function methods.IsShown(self) return self.shown end
  function methods.SetText(self, text) self.text = text end
  function methods.GetText(self) return self.text end
  function methods.SetChecked(self, value) self.checked = value end
  function methods.GetChecked(self) return self.checked end
  function methods.SetEnabled(self, value) self.enabled = value end
  function methods.SetValue(self, value) self.value = value end
  function methods.GetValue(self) return self.value end
  function methods.SetSize(self, w, h) self.width, self.height = w, h end
  function methods.SetWidth(self, w) self.width = w end
  function methods.SetHeight(self, h) self.height = h end
  function methods.GetWidth(self) return self.width end
  function methods.GetHeight(self) return self.height end
  function methods.GetVerticalScrollRange() return 0 end
  function methods.GetVerticalScroll() return 0 end
  function methods.CreateFontString() return Fakes.Frame("FontString") end
  function methods.CreateTexture() return Fakes.Frame("Texture") end
  return setmetatable(frame, {
    -- Unknown CamelCase names act as no-op widget methods; other fields are nil.
    __index = function(_, key)
      if methods[key] then return methods[key] end
      if type(key) == "string" and key:match("^%u") then return function() end end
      return nil
    end,
  })
end

function Fakes.UIGlobals()
  local created = {}
  return {
    CreateFrame = function(kind, name)
      local frame = Fakes.Frame(kind, name)
      created[#created + 1] = frame
      return frame
    end,
    UIParent = Fakes.Frame("Frame", "UIParent"),
    UISpecialFrames = {},
    SlashCmdList = {},
    created = created,
  }
end
