-- TimeSliceScheduler module
-- Cooperative multitasking: distribute work across ticks, <4s paths,
-- os.sleep(0) yields, TMI prevention.
--
-- Ensures no execution path exceeds the time slice budget per tick.
-- Automatically yields via os.sleep(0) at checkpoints to prevent
-- TMI (Too Many Instructions) errors in OpenComputers.
--
-- OC's TMI limit is approximately 4 seconds of continuous CPU without
-- yielding. This scheduler uses a default 3-second slice budget to
-- leave margin, resetting the timer after each os.sleep(0) yield.
--
-- Usage (in exec_broker.lua or supervisor.lua):
--   local Sched = require("timeslicescheduler")
--   local sched = Sched.new(3.0)
--
--   -- Per-item loop with automatic yield checkpoints
--   sched:forEach(machines, function(m) m:pollHardware() end)
--
--   -- Budget-protected batch execution
--   while sched:remaining() > 0 and work_remaining do
--     process_next_item()
--   end
--   sched:checkpoint()
--
--   -- Defer work that overran the budget
--   sched:defer(function() finish_phase() end)
--
--   -- In the event loop, drain deferred tasks
--   sched:processQueue()

local TimeSliceScheduler = {}
TimeSliceScheduler.__index = TimeSliceScheduler

-- ===========================================================================
-- Defaults
-- ===========================================================================

-- Default time slice budget in seconds.
-- OC's TMI timeout is ~4s (actual wall-clock varies by CPU model and
-- chunk-loading state). We budget 3s per slice to leave headroom for
-- component calls and edge cases.
TimeSliceScheduler.DEFAULT_BUDGET = 3.0

-- Check yield every N iterations in forEach() when iterating large
-- lists. This prevents a single long loop from consuming the entire
-- budget between budget-check calls.
TimeSliceScheduler.DEFAULT_YIELD_INTERVAL = 200

-- ===========================================================================
-- Factory
-- ===========================================================================

--- Create a new time-slice scheduler.
--- @param budgetSeconds number max wall-clock seconds per slice (default 3.0)
--- @return TimeSliceScheduler
function TimeSliceScheduler.new(budgetSeconds)
  local self = setmetatable({}, TimeSliceScheduler)
  self.budget = (budgetSeconds ~= nil and budgetSeconds >= 0) and budgetSeconds or TimeSliceScheduler.DEFAULT_BUDGET
  self._sliceStart = os.clock()
  self._yieldCount = 0
  self._resumeCount = 0
  self._totalElapsed = 0
  self._tasks = {}
  self._taskCounter = 0
  -- Detect whether os.sleep is available (OC provides it; standalone Lua
  -- does not). If os.sleep is missing, yields become no-ops so the module
  -- can be tested without an OC runtime.
  self._canSleep = (type(os.sleep) == "function")
  return self
end

-- ===========================================================================
-- Slice Budget
-- ===========================================================================

--- Reset the current slice timer (start of a new time slice).
--- Called automatically by checkpoint() after a yield.
--- Also call this at the start of each top-level work iteration.
function TimeSliceScheduler:reset()
  self._sliceStart = os.clock()
end

--- Get elapsed wall-clock time since the current slice started.
--- @return number seconds
function TimeSliceScheduler:elapsed()
  return os.clock() - self._sliceStart
end

--- Check whether the current slice budget has been consumed.
--- @return boolean
function TimeSliceScheduler:exhausted()
  return self:elapsed() >= self.budget
end

--- Get remaining time in the current slice. Returns 0 when exhausted.
--- @return number seconds remaining
function TimeSliceScheduler:remaining()
  local remain = self.budget - self:elapsed()
  return math.max(0, remain)
end

--- Get the fraction of the budget consumed (0.0 to 1.0+).
--- @return number budget fraction used
function TimeSliceScheduler:usage()
  return self:elapsed() / self.budget
end

-- ===========================================================================
-- Yielding
-- ===========================================================================

--- Yield to the OC event system via os.sleep(0).
--- In standalone Lua (no os.sleep), this is a no-op.
--- @return boolean true if a yield actually occurred
function TimeSliceScheduler:sleep()
  if self._canSleep then
    os.sleep(0)
    self._yieldCount = self._yieldCount + 1
    return true
  end
  return false
end

--- Checkpoint: yield if the current slice budget is exhausted.
--- After yielding, the slice timer resets so the next slice starts fresh.
--- This is the primary TMI prevention call -- call it at natural pause
--- points in work loops.
--- @return boolean true if a yield occurred (and budget was reset)
function TimeSliceScheduler:checkpoint()
  if self:exhausted() then
    self:sleep()
    self:reset()
    return true
  end
  return false
end

--- Yield unconditionally and start a new slice.
--- Use this when you know you've done enough work for one tick and want
--- to let other tasks run before continuing.
--- @return boolean true
function TimeSliceScheduler:checkpointNow()
  self:sleep()
  self:reset()
  return true
end

-- ===========================================================================
-- Loop Helpers
-- ===========================================================================

--- Run a single work function protected by the slice budget.
--- If the budget is already exhausted, returns immediately with
--- (false, "budget exhausted") and does NOT execute the function.
--- @param fn function work to execute
--- @param ... any arguments forwarded to fn
--- @return boolean success, any result_or_error
function TimeSliceScheduler:runProtected(fn, ...)
  if not fn then
    return false, "no function provided"
  end
  if self:remaining() <= 0 then
    return false, "budget exhausted"
  end
  return pcall(fn, ...)
end

--- Iterate over an array-style table with automatic yield checkpoints.
--- Calls checkpoint() every DEFAULT_YIELD_INTERVAL items AND after the
--- last item. This prevents long loops from consuming the entire slice
--- budget in one go.
---
--- The callback receives (item, index, scheduler). If it returns false,
--- iteration stops early (like ipairs break).
---
--- Handles errors per-item (logs silently, continues) so a single
--- failing item doesn't stall an entire batch.
---
--- @param items table array to iterate (skipped if nil or empty)
--- @param fn function(item, index, scheduler) called per item
--- @return number items processed
function TimeSliceScheduler:forEach(items, fn)
  if not items or not fn then return 0 end
  local count = 0
  for i, item in ipairs(items) do
    count = count + 1
    local ok, err = pcall(fn, item, i, self)
    if not ok then
      -- Per-item error swallowed (matched item might be transient).
      -- The caller can inspect scheduler:errors() for diagnostics.
      if not self._errors then self._errors = {} end
      table.insert(self._errors, {index = i, error = tostring(err)})
    end
    -- Periodic yield checkpoint to prevent TMI on large batches
    if count % TimeSliceScheduler.DEFAULT_YIELD_INTERVAL == 0 then
      self:checkpoint()
    end
  end
  -- Final checkpoint after the loop completes
  self:checkpoint()
  return count
end

--- Iterate over a key-value table (pairs) with yield checkpoints.
--- Calls checkpoint() every DEFAULT_YIELD_INTERVAL keys.
---
--- @param items table key-value map
--- @param fn function(key, value, scheduler) called per entry
--- @return number entries processed
function TimeSliceScheduler:forEachPair(items, fn)
  if not items or not fn then return 0 end
  local count = 0
  for k, v in pairs(items) do
    count = count + 1
    local ok, err = pcall(fn, k, v, self)
    if not ok then
      if not self._errors then self._errors = {} end
      table.insert(self._errors, {key = k, error = tostring(err)})
    end
    if count % TimeSliceScheduler.DEFAULT_YIELD_INTERVAL == 0 then
      self:checkpoint()
    end
  end
  self:checkpoint()
  return count
end

-- ===========================================================================
-- Deferred Task Queue
-- ===========================================================================

--- Enqueue a function to run in a future time slice.
--- Deferred tasks are processed by processQueue(). This is the primary
--- mechanism for breaking long work across multiple ticks.
---
--- @param fn function the task to execute
--- @param label string optional human-readable label (for debugging)
--- @return number taskId positive integer
function TimeSliceScheduler:defer(fn, label)
  if not fn then return nil end
  self._taskCounter = self._taskCounter + 1
  table.insert(self._tasks, {
    id = self._taskCounter,
    fn = fn,
    label = label or ("task-" .. self._taskCounter),
  })
  return self._taskCounter
end

--- Process pending deferred tasks, respecting the slice budget.
--- Each task is executed in order; if budget runs out mid-queue, the
--- scheduler yields and the remaining tasks are deferred to the next
--- call. Optionally limit the number of tasks processed per call.
---
--- @param maxTasks number max tasks to process (0 or nil = unlimited,
---                 subject to slice budget)
--- @return number tasks processed in this call
function TimeSliceScheduler:processQueue(maxTasks)
  maxTasks = maxTasks or 0
  local processed = 0
  while #self._tasks > 0 do
    -- Check budget before each task; if exhausted, yield + reset
    if self:exhausted() then
      self:sleep()
      self:reset()
      -- After sleep+reset, continue processing remaining tasks
    end
    -- Respect maxTasks cap if set
    if maxTasks > 0 and processed >= maxTasks then
      break
    end
    local task = table.remove(self._tasks, 1)
    local ok, err = pcall(task.fn)
    if not ok then
      if not self._errors then self._errors = {} end
      table.insert(self._errors, {
        taskId = task.id,
        label = task.label,
        error = tostring(err),
      })
    end
    processed = processed + 1
  end
  return processed
end

--- Get the number of pending (unprocessed) deferred tasks.
--- @return number
function TimeSliceScheduler:pendingTasks()
  return #self._tasks
end

--- Clear all pending deferred tasks without executing them.
function TimeSliceScheduler:clearQueue()
  self._tasks = {}
end

-- ===========================================================================
-- Error Inspection
-- ===========================================================================

--- Retrieve and optionally clear accumulated errors from forEach/processQueue.
--- @param clear boolean if true, clear the error log after reading
--- @return table array of error records
function TimeSliceScheduler:errors(clear)
  local result = self._errors or {}
  if clear then
    self._errors = nil
  end
  return result
end

-- ===========================================================================
-- Statistics & Diagnostics
-- ===========================================================================

--- Get cumulative statistics for diagnostic purposes.
--- @return table { yields, elapsed, pendingTasks, ... }
function TimeSliceScheduler:stats()
  return {
    yields = self._yieldCount,
    elapsed = self:elapsed(),
    budgetUsage = self:usage(),
    pendingTasks = #self._tasks,
    budget = self.budget,
    canSleep = self._canSleep,
  }
end

--- Reset all counters (yield count, resume count, total elapsed).
--- Does NOT reset the slice timer or clear the task queue.
function TimeSliceScheduler:resetStats()
  self._yieldCount = 0
  self._resumeCount = 0
  self._totalElapsed = 0
end

return TimeSliceScheduler
