-- Feedback: visible progress of a user-started scan.
-- A handful of chat lines per scan (requested, receiving, reading N rows,
-- retry, outcome with counts and duration, analysis done) and the progress
-- bar of the main window. Passive observations of the user's own searches
-- stay silent: they would otherwise print on every AH search.
local _, ns = ...

local Feedback = {}
ns.UI.Feedback = Feedback

local function L(key) return ns.L[key] or key end

local function reasonText(reason)
  if not reason then return "" end
  local key = tostring(reason):match("^([%w_]+)")
  return ns.L["REASON_" .. key] or tostring(reason)
end

-- "10 min 6 s", "45 s".
function Feedback.Duration(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  local minutes = math.floor(seconds / 60)
  if minutes == 0 then return seconds .. " s" end
  local rest = seconds - minutes * 60
  if rest == 0 then return minutes .. " min" end
  return minutes .. " min " .. rest .. " s"
end

-- What we know about the replicate cooldown, as one sentence.
function Feedback.CooldownText(app)
  local info = app.scanner:Cooldown()
  if not info.lowerBound and not info.upperBound then return L("CD_UNKNOWN") end
  if info.lowerBound and info.upperBound then
    return string.format(L("CD_RANGE"), Feedback.Duration(info.lowerBound), Feedback.Duration(info.upperBound))
  end
  local text = info.lowerBound and string.format(L("CD_LOWER"), Feedback.Duration(info.lowerBound)) or ""
  if info.upperBound then
    text = text .. (text ~= "" and "; " or "") .. string.format(L("CD_UPPER"), Feedback.Duration(info.upperBound))
  end
  return text
end

-- Chat line when a scan cannot start.
function Feedback.RefusedLine(app, reason, seconds, kind)
  if reason == "cooldown" and kind == "measured" then
    return string.format(L("FB_COOLDOWN_MEASURED"), Feedback.Duration(seconds), Feedback.CooldownText(app))
  elseif reason == "cooldown" then
    return string.format(L("FB_COOLDOWN"), Feedback.Duration(seconds), Feedback.CooldownText(app))
  end
  return L("SCAN_REFUSED") .. " " .. reasonText(reason)
end

-- Starts a user scan and reports a refusal.
function Feedback.StartScan(app)
  local ok, reason, seconds, kind = app.scanner:Start({ mode = "replicate" })
  if not ok then ns.Print(Feedback.RefusedLine(app, reason, seconds, kind)) end
  return ok
end

local function userScan(snapshot)
  return snapshot and snapshot.mode == "replicate"
end

-- Chat line for a scanner state, or nil when nothing needs saying.
function Feedback.StateLine(app, state, reason, snapshot)
  if not userScan(snapshot) then return nil end
  if state == "REQUESTED" then
    local task = app.scanner.task
    if task and task.attempts and task.attempts > 1 then
      return string.format(L("FB_RETRY"), task.attempts, app.scanner.opts.maxRetries + 1)
    end
    return L("FB_REQUESTED")
  elseif state == "THROTTLED" then
    return L("FB_THROTTLED")
  elseif state == "RECEIVING" then
    return L("FB_RECEIVING")
  elseif state == "COMPLETE" or state == "PARTIAL" then
    local c = snapshot.counts
    local seconds = (snapshot.finished or 0) - (snapshot.started or 0)
    local line = string.format(L("FB_DONE"), seconds, c.itemKeys, c.valid, c.units)
    if state == "PARTIAL" then line = line .. " " .. L("STATE_PARTIAL") .. ": " .. reasonText(reason) end
    return line
  elseif state == "FAILED" and reason == "no_response" then
    return string.format(L("FB_NO_RESPONSE"), app.scanner.opts.timeout, Feedback.CooldownText(app))
  elseif state == "FAILED" then
    return L("FB_FAILED") .. " " .. reasonText(reason)
  elseif state == "CANCELLED" then
    return L("FB_CANCELLED") .. " " .. reasonText(reason)
  end
  return nil
end

Feedback.SUMMARY_WAIT = 8

-- "AH search test": read-only probe, progress and summary in chat.
function Feedback.StartProbe(app)
  local ok, reason = app.probe:Start()
  if not ok then ns.Print(L("PROBE_REFUSED_" .. tostring(reason))) end
  return ok
end

function Feedback.Attach(app)
  local Main = ns.UI.Main
  app.bus:Subscribe("probe.progress", function(kind, data)
    if kind == "step" then
      ns.Print(string.format(L("PROBE_STEP"), data.index, data.total, data.name or "?"))
    elseif kind == "done" then
      ns.Print(string.format(L("PROBE_DONE"), data.variants, data.lots, data.votes.total, data.votes.unit))
    end
  end)
  local summary = ns.Core.Scheduler.New(app.schedulerEnv)
  local awaitingSummary = false
  local function trySummary(force)
    local results = app.opportunities.results
    if not awaitingSummary or not results then return false end
    local c = results.counts
    if not force and ((c.infoPending or 0) > 0 or (c.commodityPending or 0) > 0) then return false end
    awaitingSummary = false
    summary:Invalidate()
    ns.Print(string.format(L("FB_ANALYZED"), #results.list, results.counts.candidates, results.counts.itemKeys))
    return true
  end
  app.bus:Subscribe("opportunities.updated", function() trySummary() end)
  -- Once a second while waiting for the server: elapsed time on the bar.
  local ticker = ns.Core.Scheduler.New(app.schedulerEnv)
  local function tick()
    local progress = Main.progress
    if not progress or progress.phase ~= "waiting" or not app.scanner:IsActive() then return end
    progress.elapsed = app.clock() - (progress.since or app.clock())
    Main.UpdateProgress()
    ticker:After(1, tick)
  end
  app.bus:Subscribe("scanner.state", function(state, reason, snapshot)
    local line = Feedback.StateLine(app, state, reason, snapshot)
    if line then ns.Print(line) end
    if userScan(snapshot) then
      if state == "FAILED" or state == "CANCELLED" then
        Main.SetProgress(nil)
      elseif state == "RECEIVING" then
        Main.SetProgress({ phase = "receiving" })
      elseif app.scanner:IsActive() then
        ticker:Invalidate()
        Main.SetProgress({ phase = "waiting", since = app.clock(), elapsed = 0, timeout = app.scanner.opts.timeout })
        ticker:After(1, tick)
      end
    end
    Main.RefreshTable()
  end)
  app.bus:Subscribe("scanner.progress", function(phase, done, total, snapshot)
    if not userScan(snapshot) then return end
    if phase == "read" and done == 0 then ns.Print(string.format(L("FB_READING"), total)) end
    Main.SetProgress({ phase = phase, done = done, total = total })
  end)
  app.bus:Subscribe("pipeline.progress", function(phase, done, total, mode)
    if mode ~= "replicate" then return end
    if phase == "done" then
      Main.SetProgress(nil)
      summary:Invalidate()
      awaitingSummary = true
      -- Item data (vendor prices, commodity status) keeps arriving after
      -- the first pass: report once it settles, or after a short wait.
      if not trySummary() then summary:After(Feedback.SUMMARY_WAIT, function() trySummary(true) end) end
      return
    end
    Main.SetProgress({ phase = phase, done = done, total = total })
  end)
end
