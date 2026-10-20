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
  elseif state == "FAILED" then
    return L("FB_FAILED") .. " " .. reasonText(reason)
  elseif state == "CANCELLED" then
    return L("FB_CANCELLED") .. " " .. reasonText(reason)
  end
  return nil
end

function Feedback.Attach(app)
  local Main = ns.UI.Main
  app.bus:Subscribe("scanner.state", function(state, reason, snapshot)
    local line = Feedback.StateLine(app, state, reason, snapshot)
    if line then ns.Print(line) end
    if userScan(snapshot) then
      if state == "FAILED" or state == "CANCELLED" then
        Main.SetProgress(nil)
      elseif app.scanner:IsActive() then
        Main.SetProgress({ phase = state == "RECEIVING" and "receiving" or "waiting" })
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
      local results = app.opportunities.results
      if results then
        ns.Print(string.format(L("FB_ANALYZED"), #results.list, results.counts.candidates, results.counts.itemKeys))
      end
      return
    end
    Main.SetProgress({ phase = phase, done = done, total = total })
  end)
end
