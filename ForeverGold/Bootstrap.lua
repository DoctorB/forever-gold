-- ForeverGold: namespace bootstrap.
-- Every file receives (addonName, ns) from the client loader; the offline test
-- runner reproduces the same contract. No globals are created here.
local addonName, ns = ...

ns.ADDON_NAME = addonName or "ForeverGold"
ns.VERSION = "0.1.0-alpha.2"

-- Session-wide placeholders filled by later files in TOC order.
ns.Core = ns.Core or {}
ns.Compat = ns.Compat or {}
ns.Data = ns.Data or {}
ns.Economy = ns.Economy or {}
ns.Strategies = ns.Strategies or {}
ns.Services = ns.Services or {}
ns.UI = ns.UI or {}

-- Local output only.
function ns.Print(message)
  local frame = ns.outputFrame
  if not frame and type(DEFAULT_CHAT_FRAME) == "table" then
    frame = DEFAULT_CHAT_FRAME
  end
  local line = "|cffe6b422ForeverGold|r: " .. tostring(message)
  if frame and type(frame.AddMessage) == "function" then
    frame:AddMessage(line)
  elseif type(print) == "function" then
    print(line)
  end
end

-- Shallow-safe deep copy for plain data tables (no metatables, no cycles).
function ns.CopyTable(value)
  if type(value) ~= "table" then return value end
  local copy = {}
  for key, inner in pairs(value) do
    copy[key] = ns.CopyTable(inner)
  end
  return copy
end
