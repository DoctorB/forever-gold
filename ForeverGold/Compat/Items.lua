-- ItemProvider: asynchronous item metadata with a bounded queue.
--   ItemProvider:Resolve(itemID, callback(info | nil, reason))
-- A cold cache never blocks: missing data is requested, callbacks are
-- deduplicated per item and expire after a timeout. Data arriving after the
-- timeout still reaches onResolved(itemID). sellPrice nil stays nil.
local _, ns = ...

local Items = {}
ns.Compat.Items = Items

Items.MAX_PENDING = 200
Items.TIMEOUT = 5

function Items.New(client, scheduler, onResolved)
  return setmetatable({
    client = client, scheduler = scheduler, onResolved = onResolved, cache = {}, pending = {}, pendingCount = 0,
    requested = {},
  }, { __index = Items })
end

-- Synchronous read; nil when the client has no data yet.
function Items:Read(itemID)
  local cached = self.cache[itemID]
  if cached then return cached end
  local c = self.client
  local ok, name, link, quality, _, _, _, _, stackCount, _, _, sellPrice, classID, subclassID, bindType =
    c:Call("C_Item", "GetItemInfo", itemID)
  if not ok then
    ok, name, link, quality, _, _, _, _, stackCount, _, _, sellPrice, classID, subclassID, bindType =
      c:Call(nil, "GetItemInfo", itemID)
  end
  if not ok or type(name) ~= "string" then return nil end
  if c:IsSecret(sellPrice) then sellPrice = nil end
  local info = {
    itemID = itemID, name = name, link = link, quality = quality, stackCount = stackCount,
    sellPrice = type(sellPrice) == "number" and sellPrice or nil,
    classID = classID, subclassID = subclassID, bindType = bindType,
  }
  self.cache[itemID] = info
  return info
end

local function finish(self, itemID, info, reason)
  local waiting = self.pending[itemID]
  if not waiting then return end
  self.pending[itemID] = nil
  self.pendingCount = self.pendingCount - 1
  if waiting.timer then waiting.timer.Cancel() end
  for _, callback in ipairs(waiting.callbacks) do callback(info, reason) end
end

function Items:Resolve(itemID, callback)
  local info = self:Read(itemID)
  if info then
    callback(info)
    return
  end
  local waiting = self.pending[itemID]
  if waiting then
    waiting.callbacks[#waiting.callbacks + 1] = callback
    return
  end
  if self.pendingCount >= Items.MAX_PENDING then
    callback(nil, "queue_full")
    return
  end
  waiting = { callbacks = { callback } }
  self.pending[itemID] = waiting
  self.requested[itemID] = true
  self.pendingCount = self.pendingCount + 1
  self.client:Call("C_Item", "RequestLoadItemDataByID", itemID)
  waiting.timer = self.scheduler:After(Items.TIMEOUT, function()
    finish(self, itemID, self:Read(itemID), "timeout")
  end)
end

-- GET_ITEM_INFO_RECEIVED(itemID, success)
function Items:OnItemInfo(itemID, success)
  if not self.requested[itemID] then return end
  if success == false then
    self.requested[itemID] = nil
    finish(self, itemID, nil, "load_failed")
    return
  end
  local info = self:Read(itemID)
  if not info then return end
  self.requested[itemID] = nil
  finish(self, itemID, info)
  if self.onResolved then self.onResolved(itemID) end
end
