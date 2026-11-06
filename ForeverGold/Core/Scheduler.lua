-- Scheduler: timers bound to a generation, bounded backoff with jitter and
-- frame-budgeted chunk processing. Clock, timer and random source are
-- injected so the scanner can be replayed offline.
--   env = { now() seconds, preciseMs() milliseconds, after(delay, fn), random() [0,1) }
local _, ns = ...

local Scheduler = {}
ns.Core.Scheduler = Scheduler

function Scheduler.New(env)
  return setmetatable({ env = env, generation = 1, pending = 0 }, { __index = Scheduler })
end

-- Cancels every timer and chunk loop started before this call.
function Scheduler:Invalidate()
  self.generation = self.generation + 1
  return self.generation
end

-- Runs fn after delay unless the generation changed or the handle was
-- cancelled. Returns a handle with :Cancel().
function Scheduler:After(delay, fn)
  local generation = self.generation
  local handle = { cancelled = false }
  function handle.Cancel() handle.cancelled = true end
  self.pending = self.pending + 1
  self.env.after(delay, function()
    self.pending = self.pending - 1
    if handle.cancelled or generation ~= self.generation then return end
    fn()
  end)
  return handle
end

-- Exponential backoff with jitter, capped. attempt starts at 1.
function Scheduler:Backoff(attempt, base, cap)
  local delay = base * (2 ^ (attempt - 1))
  if delay > cap then delay = cap end
  local jitter = (self.env.random and self.env.random() or 0.5) * base
  return delay + jitter
end

-- Calls step(index) for index = first..last, spending at most budgetMs per
-- frame; continues on the next frame through after(0). done(completed,
-- handle) is called once, with false when cancelled. Returns a handle with
-- :Cancel(); it also measures the work: frames, worstMs (longest frame),
-- busyMs (all frames together), steps, and the slowest single step
-- (slowestMs, slowestIndex).
function Scheduler:Chunk(first, last, budgetMs, step, done)
  local index = first
  local handle = { cancelled = false, frames = 0, worstMs = 0, busyMs = 0, steps = last - first + 1, slowestMs = 0 }
  local generation = self.generation
  function handle.Cancel() handle.cancelled = true end
  local function account(started)
    local spent = self.env.preciseMs() - started
    handle.busyMs = handle.busyMs + spent
    if spent > handle.worstMs then handle.worstMs = spent end
  end
  local function tick()
    if handle.cancelled or generation ~= self.generation then
      if done then done(false, handle) end
      return
    end
    handle.frames = handle.frames + 1
    local started = self.env.preciseMs()
    local before, nowMs = started, started
    repeat
      if index > last then
        account(started)
        if done then done(true, handle) end
        return
      end
      step(index)
      nowMs = self.env.preciseMs()
      if nowMs - before > handle.slowestMs then handle.slowestMs, handle.slowestIndex = nowMs - before, index end
      before = nowMs
      index = index + 1
    until nowMs - started >= budgetMs
    account(started)
    self.env.after(0, tick)
  end
  tick()
  return handle
end
