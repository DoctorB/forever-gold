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
-- frame; continues on the next frame through after(0). done(completed) is
-- called once, with false when cancelled. Returns a handle with :Cancel().
function Scheduler:Chunk(first, last, budgetMs, step, done)
  local index = first
  local handle = { cancelled = false, frames = 0 }
  local generation = self.generation
  function handle.Cancel() handle.cancelled = true end
  local function tick()
    if handle.cancelled or generation ~= self.generation then
      if done then done(false) end
      return
    end
    handle.frames = handle.frames + 1
    local started = self.env.preciseMs()
    repeat
      if index > last then
        if done then done(true) end
        return
      end
      step(index)
      index = index + 1
    until self.env.preciseMs() - started >= budgetMs
    self.env.after(0, tick)
  end
  tick()
  return handle
end
