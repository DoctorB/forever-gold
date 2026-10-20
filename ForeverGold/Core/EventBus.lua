-- EventBus: internal publish/subscribe between services and UI.
-- Unrelated to client events; a failing listener is contained and logged so
-- one broken view cannot stop a scan.
local _, ns = ...

local EventBus = {}
ns.Core.EventBus = EventBus

function EventBus.New(logger)
  return setmetatable({ listeners = {}, logger = logger }, { __index = EventBus })
end

function EventBus:Subscribe(name, fn)
  local list = self.listeners[name]
  if not list then
    list = {}
    self.listeners[name] = list
  end
  list[#list + 1] = fn
  return fn
end

function EventBus:Unsubscribe(name, fn)
  local list = self.listeners[name]
  if not list then return end
  for index = #list, 1, -1 do
    if list[index] == fn then table.remove(list, index) end
  end
end

function EventBus:Publish(name, ...)
  local list = self.listeners[name]
  if not list then return end
  -- Copy: listeners may unsubscribe while running.
  local snapshot = {}
  for index = 1, #list do snapshot[index] = list[index] end
  for _, fn in ipairs(snapshot) do
    local ok, err = pcall(fn, ...)
    if not ok and self.logger then self.logger("listener " .. name .. ": " .. tostring(err)) end
  end
end
