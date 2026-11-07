-- AutoScan: optional read-only AH scan as soon as the replicate cooldown
-- ends, while the AH window is open (e.g. while the player is away).
-- Off by default (setting autoScan). It only asks for the replica; it never
-- buys, posts or cancels (spec 12: reads may be automated, spending needs a
-- click).
--
-- Whether the client accepts ReplicateItems without a click is not
-- verified on Forever: the first automatic request is the test. If the
-- client reports the call as blocked (ADDON_ACTION_BLOCKED/FORBIDDEN naming
-- this add-on right after the request), auto-scan switches itself off and
-- says so. After MAX_SILENT unanswered requests in a row it stops until the
-- AH window is opened again (silent requests do not shorten the cooldown).
-- Evidence is kept in ForeverGoldDB.autoScan.
--
-- Bus: "autoscan.state"(self)
local _, ns = ...

local AutoScan = {}
ns.Services.AutoScan = AutoScan

AutoScan.TICK = 5 -- seconds between checks while the AH is open
AutoScan.MAX_SILENT = 3
AutoScan.BLOCK_WINDOW = 3 -- seconds after a request in which a block is ours
AutoScan.ADDON = "ForeverGold"

-- deps: { scanner, ah, scheduler, clock, settings() -> table, busy() -> bool,
--         memory (persisted table), bus?, trace?(kind, data) }
function AutoScan.New(deps)
  local self = setmetatable(deps, { __index = AutoScan })
  self.memory.attempts = self.memory.attempts or 0
  self.memory.answered = self.memory.answered or 0
  self.memory.silent = self.memory.silent or 0
  self.silentInRow, self.stopped, self.pending = 0, nil, false
  return self
end

function AutoScan:Enabled()
  return self.settings().autoScan == true and not self.memory.blocked
end

local function publish(self)
  if self.bus then self.bus:Publish("autoscan.state", self) end
end

local function trace(self, kind, data)
  if self.trace then self.trace(kind, data) end
end

function AutoScan:Schedule()
  if self.timer then return end
  self.timer = self.scheduler:After(AutoScan.TICK, function()
    self.timer = nil
    self:Tick()
  end)
end

-- The setting changed from the Settings tab.
function AutoScan:SetEnabled(value)
  self.settings().autoScan = value == true
  if value then
    -- Switching it on again is the owner's decision to retry.
    self.memory.blocked, self.stopped, self.silentInRow = nil, nil, 0
    if self.ah:IsOpen() then self:Tick() end
  end
  publish(self)
end

function AutoScan:OnShow()
  self.stopped, self.silentInRow = nil, 0
  if self:Enabled() then self:Tick() end
  publish(self)
end

function AutoScan:OnClose()
  if self.timer then
    self.timer.Cancel()
    self.timer = nil
  end
  self.pending = false
  publish(self)
end

-- One check: request the replica when nothing else runs and the cooldown
-- (or a replica already held by the client) allows a useful scan.
function AutoScan:Tick()
  if not self:Enabled() or not self.ah:IsOpen() or self.stopped then return end
  if not self.pending and not self.scanner:IsActive() and not (self.busy and self.busy()) then
    if self.scanner:Wait() <= 0 then
      local ok, reason = self.scanner:Start({ mode = "replicate" })
      trace(self, "auto_scan", { ok = ok, reason = reason })
      if ok then
        self.pending, self.requestedAt = true, self.clock()
        self.memory.attempts = self.memory.attempts + 1
        self.memory.lastAt = self.requestedAt
        publish(self)
      end
    end
  end
  self:Schedule()
end

-- Scanner states (wired by Core/App): only the request this service made.
function AutoScan:OnScannerState(state, reason)
  if not self.pending then return end
  if state == "COMPLETE" or state == "PARTIAL" then
    self.pending, self.silentInRow = false, 0
    self.justAnswered = true -- read by Core/App after the evaluation (alert)
    self.memory.answered = self.memory.answered + 1
    self.memory.lastAnswerAt = self.clock()
  elseif state == "FAILED" or state == "CANCELLED" then
    self.pending = false
    if reason == "no_response" then
      self.silentInRow = self.silentInRow + 1
      self.memory.silent = self.memory.silent + 1
      if self.silentInRow >= AutoScan.MAX_SILENT then self.stopped = "silent" end
    end
  else
    return
  end
  publish(self)
end

-- ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN (addonName, functionName).
function AutoScan:OnBlocked(event, addon, fn)
  trace(self, "action_blocked", { event = event, addon = addon, fn = fn })
  if addon ~= AutoScan.ADDON or not self.requestedAt then return false end
  if self.clock() - self.requestedAt > AutoScan.BLOCK_WINDOW then return false end
  self.memory.blocked = { at = self.clock(), event = event, fn = fn }
  self.settings().autoScan = false
  self.pending, self.stopped = false, "blocked"
  if self.timer then
    self.timer.Cancel()
    self.timer = nil
  end
  publish(self)
  return true
end

-- What the status line says: kind ("off", "blocked", "silent", "scanning",
-- "waiting", "closed") and seconds to the next request when waiting.
function AutoScan:Status()
  if self.memory.blocked then return "blocked" end
  if self.settings().autoScan ~= true then return "off" end
  if self.stopped then return self.stopped end
  if not self.ah:IsOpen() then return "closed" end
  if self.pending or self.scanner:IsActive() then return "scanning" end
  return "waiting", math.max(0, math.floor(self.scanner:Wait() + 0.5))
end
