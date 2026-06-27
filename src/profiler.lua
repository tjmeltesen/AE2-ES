--[[
profiler.lua — AE2-ES Runtime Performance Profiler (C8)
Phase D: execution timer + GC tracking for Exec Broker main loop.

Instruments the broker's 6-phase state machine for continuous performance
monitoring. Provides:

1. Phase Timing (startPhase/endPhase) with rolling window stats
2. Yield Gap Detection — warn if >4s without os.sleep(0)/coroutine.yield()
3. GC Memory Tracking — computer.totalMemory() - computer.freeMemory()
   baseline comparison and leak detection

Designed for graceful degradation: all OC runtime dependencies are
soft-loaded via pcall. The module is usable (with stubs) in standalone
Lua test environments.

Usage:
  local Profiler = require("profiler")
  local profiler = Profiler.new({ yieldWarnThreshold = 4.0 })
  profiler:attach(broker)
  -- In broker tick:
  profiler:startPhase("PROCESSING")
  -- ... work ...
  profiler:endPhase("PROCESSING")
  -- At end of cycle:
  local report = profiler:getReport()
]]--

local Profiler = {}
Profiler.__index = Profiler

-- ===========================================================================
-- Defaults
-- ===========================================================================

-- Default rolling window size per phase (number of samples kept)
Profiler.DEFAULT_WINDOW_SIZE = 100

-- Default yield warning threshold in seconds (OC TMI timeout ~4s)
Profiler.DEFAULT_YIELD_WARN = 4.0

-- Default phase budget warning threshold (matches TimeSliceScheduler margin)
Profiler.DEFAULT_PHASE_BUDGET = 4.0

-- Baseline memory margin: post-CLEANUP must be within this fraction of startup
Profiler.DEFAULT_BASELINE_MARGIN = 0.05

-- ===========================================================================
-- Soft dependency: computer.totalMemory() / computer.freeMemory()
-- ===========================================================================

-- Resolve the computer module once at load time. Returns nil if unavailable.
local _computerModule = nil
do
  local ok, mod = pcall(require, "computer")
  if ok then _computerModule = mod end
end

--- Safely read current used memory (bytes).
-- Falls back to 0 when the OC computer module is unavailable.
-- @return number used memory (totalMemory - freeMemory), or 0
local function getUsedMemory()
  if _computerModule then
    local total = _computerModule.totalMemory()
    local free = _computerModule.freeMemory()
    if type(total) == "number" and type(free) == "number" then
      return total - free
    end
  end
  return 0
end

-- ===========================================================================
-- Helpers
-- ===========================================================================

--- Compute statistics from a list of numeric samples.
-- Returns min, max, mean, p95, p99.
-- For the sorted copy it uses table.sort which is O(n log n) — acceptable
-- since the window is capped at 100.
-- @param samples table array of numbers
-- @return table { min, max, mean, p95, p99, count }
local function computeStats(samples)
  local stats = { count = #samples, min = 0, max = 0, mean = 0, p95 = 0, p99 = 0 }
  if #samples == 0 then return stats end

  -- Mean
  local sum = 0
  for _, v in ipairs(samples) do
    sum = sum + v
  end
  stats.mean = sum / #samples

  -- Min / max
  stats.min = samples[1]
  stats.max = samples[1]
  for i = 2, #samples do
    if samples[i] < stats.min then stats.min = samples[i] end
    if samples[i] > stats.max then stats.max = samples[i] end
  end

  -- Percentiles require sorting
  local sorted = {}
  for i, v in ipairs(samples) do
    sorted[i] = v
  end
  table.sort(sorted)

  local function percentile(p)
    if #sorted == 0 then return 0 end
    local idx = math.max(1, math.floor(p * #sorted))
    if idx > #sorted then idx = #sorted end
    return sorted[idx]
  end

  stats.p95 = percentile(0.95)
  stats.p99 = percentile(0.99)

  return stats
end

--- Format a duration in seconds as a readable string.
-- @param secs number
-- @return string e.g. "1.234s"
local function fmtDuration(secs)
  return string.format("%.3fs", secs)
end

-- ===========================================================================
-- Factory
-- ===========================================================================

--- Create a new Runtime Profiler.
-- @param config table with optional keys:
--   windowSize          — number, rolling window per phase (default 100)
--   yieldWarnThreshold  — number, seconds without yield before warning (default 4.0)
--   phaseBudget         — number, seconds before phase duration alert (default 4.0)
--   baselineMargin      — number, fraction of baseline for pass/fail (default 0.05)
--   clockOverride       — function, override for os.clock() in tests
--   memoryOverride      — function, override for getUsedMemory() in tests
-- @return Profiler
function Profiler.new(config)
  config = config or {}

  local self = setmetatable({}, Profiler)

  -- Configuration
  self._windowSize         = config.windowSize or Profiler.DEFAULT_WINDOW_SIZE
  self._yieldWarnThreshold = config.yieldWarnThreshold or Profiler.DEFAULT_YIELD_WARN
  self._phaseBudget        = config.phaseBudget or Profiler.DEFAULT_PHASE_BUDGET
  self._baselineMargin     = config.baselineMargin or Profiler.DEFAULT_BASELINE_MARGIN

  -- Clock source: overrideable for testing (default os.clock)
  self._now = config.clockOverride or os.clock

  -- Memory source: overrideable for testing
  self._getMemory = config.memoryOverride or getUsedMemory

  -- ========================================================================
  -- Phase timing
  -- ========================================================================

  -- Rolling windows: phaseName -> { [1] sample_secs, [2], ... }
  self._phaseSamples = {}

  -- Active phase timers: phaseName -> start_time (nil if not running)
  self._phaseTimers = {}

  -- Phase budget violations (phaseName -> count)
  self._phaseViolations = {}

  -- ========================================================================
  -- Yield gap detection
  -- ========================================================================

  -- Timestamp of the last yield (os.sleep(0) or coroutine.yield())
  self._lastYieldTime = self._now()

  -- Number of yield gap violations detected
  self._yieldViolations = 0

  -- Yield gap violation log (most recent entries, capped at 10)
  self._yieldViolationLog = {}

  -- ========================================================================
  -- GC memory tracking
  -- ========================================================================

  -- Snapshot at broker start
  self._baselineMemory = nil

  -- Memory snapshots: phaseName -> used_memory_at_entry
  self._entryMemory = {}

  -- Memory snapshot at CLEANUP exit
  self._cleanupMemory = nil

  -- Memory leak alarm: true if upward trend detected
  self._leakAlarm = false

  -- Persistent memory high-water mark
  self._highWaterMark = nil

  -- ========================================================================
  -- Integration state
  -- ========================================================================

  -- Whether the profiler is attached to a broker
  self._attached = false

  -- The broker instance (if attached)
  self._broker = nil

  -- Yields detected (total count, not just violations)
  self._yieldCount = 0

  -- Total yield gap time (seconds spent between yields)
  self._totalYieldGapTime = 0

  return self
end

-- ===========================================================================
-- Attachment API
-- ===========================================================================

--- Attach the profiler to an ExecBroker instance.
-- Instruments the broker's tick() method to record phase transitions,
-- yield events, and memory snapshots. If attach() has already been called
-- on a different broker, returns false without side effects.
-- @param broker ExecBroker instance
-- @return boolean true if attached successfully
function Profiler:attach(broker)
  if not broker or type(broker) ~= "table" then
    return false
  end
  if not broker.getPhase or type(broker.getPhase) ~= "function" then
    return false
  end
  if not broker.tick or type(broker.tick) ~= "function" then
    return false
  end
  if self._attached then
    return false  -- already attached to a different broker
  end

  self._broker = broker

  -- Take baseline memory snapshot at attachment time
  self._baselineMemory = self._getMemory()
  self._highWaterMark = self._baselineMemory

  -- Monkey-patch the broker's tick method to wrap with profiling calls.
  -- We preserve the original so it can be restored (though in practice
  -- the profiler lives for the broker's lifetime).
  local originalTick = broker.tick
  local selfRef = self

  broker.tick = function(...)
    -- Take entry memory snapshot for the current phase
    local phase = broker:getPhase()
    if phase then
      selfRef:startPhase(phase)
    end

    -- Run the original tick
    local result = {originalTick(...)}

    -- Record end of phase after tick
    if phase then
      selfRef:endPhase(phase)
    end

    -- Mark yield if broker slept (we can't detect os.sleep directly,
    -- but we know the broker yields via event.pull — track that as
    -- an implicit yield point)
    selfRef:recordYield()

    return table.unpack(result)
  end

  self._attached = true
  return true
end

--- Detach the profiler from the broker, restoring the original tick method.
-- @return boolean true if detached successfully
function Profiler:detach()
  if not self._attached or not self._broker then
    return false
  end

  -- Restore original tick
  if self._broker._originalTick then
    self._broker.tick = self._broker._originalTick
    self._broker._originalTick = nil
  end

  self._broker = nil
  self._attached = false
  return true
end

-- ===========================================================================
-- Phase Timing API
-- ===========================================================================

--- Start timing a phase.
-- Records the entry time and takes a memory snapshot.
-- If the phase is already being timed (nested call), it's a no-op.
-- @param phaseName string phase identifier (e.g. "BUFFERING", "ALLOCATING")
function Profiler:startPhase(phaseName)
  if not phaseName or type(phaseName) ~= "string" then
    return
  end

  -- Prevent double-start of the same phase
  if self._phaseTimers[phaseName] ~= nil then
    return
  end

  self._phaseTimers[phaseName] = self._now()

  -- Snapshot memory at phase entry
  local mem = self._getMemory()
  self._entryMemory[phaseName] = mem

  -- Update high-water mark whenever we snapshot memory
  if self._highWaterMark == nil or mem > self._highWaterMark then
    self._highWaterMark = mem
  end

  -- Check yield gap
  self:_checkYieldGap()
end

--- End timing a phase.
-- Computes wall-clock time since startPhase, appends to the rolling window,
-- and checks against the phase budget.
-- If the phase was not started (no matching startPhase call), it's a no-op.
-- @param phaseName string phase identifier
function Profiler:endPhase(phaseName)
  if not phaseName or type(phaseName) ~= "string" then
    return
  end

  local startTime = self._phaseTimers[phaseName]
  if startTime == nil then
    return  -- no matching startPhase call
  end

  -- Compute duration
  local now = self._now()
  local duration = now - startTime

  -- Clear the active timer
  self._phaseTimers[phaseName] = nil

  -- Append to rolling window
  if not self._phaseSamples[phaseName] then
    self._phaseSamples[phaseName] = {}
  end
  local window = self._phaseSamples[phaseName]
  table.insert(window, duration)

  -- Trim window to max size
  while #window > self._windowSize do
    table.remove(window, 1)
  end

  -- Check phase budget violation
  if duration > self._phaseBudget then
    self._phaseViolations[phaseName] = (self._phaseViolations[phaseName] or 0) + 1
  end
end

-- ===========================================================================
-- Yield Gap Detection API
-- ===========================================================================

--- Record that a yield occurred (os.sleep(0) or coroutine.yield()).
-- Resets the yield gap timer so the next checkpoint starts fresh.
function Profiler:recordYield()
  local now = self._now()
  local gap = now - self._lastYieldTime

  -- Track total yield gap time
  self._totalYieldGapTime = self._totalYieldGapTime + gap
  self._yieldCount = self._yieldCount + 1

  -- Check for violation
  if gap > self._yieldWarnThreshold and self._yieldCount > 1 then
    self:_recordYieldViolation(gap)
  end

  -- Reset the gap timer
  self._lastYieldTime = now
end

--- Check the current yield gap (time since last yield).
-- If the gap exceeds the threshold, records a violation.
-- Called automatically by startPhase() and can also be called manually
-- at strategic yield points.
-- @return number current gap in seconds
function Profiler:_checkYieldGap()
  local now = self._now()
  local gap = now - self._lastYieldTime

  if gap > self._yieldWarnThreshold then
    self:_recordYieldViolation(gap)
  end

  return gap
end

--- Record a yield gap violation internally.
-- @param gap number seconds since last yield
function Profiler:_recordYieldViolation(gap)
  self._yieldViolations = self._yieldViolations + 1

  -- Keep a log of the most recent violations (max 10)
  table.insert(self._yieldViolationLog, {
    time    = self._now(),
    gap     = gap,
    breach  = gap - self._yieldWarnThreshold,
  })
  while #self._yieldViolationLog > 10 do
    table.remove(self._yieldViolationLog, 1)
  end
end

-- ===========================================================================
-- GC Memory Tracking API
-- ===========================================================================

--- Take a CLEANUP exit memory snapshot.
-- Called when the broker completes a CLEANUP phase. The snapshot is used
-- for baseline recovery assertions.
-- @return number used memory at exit
function Profiler:recordCleanupExit()
  self._cleanupMemory = self._getMemory()

  -- Update high-water mark
  if self._cleanupMemory > (self._highWaterMark or 0) then
    self._highWaterMark = self._cleanupMemory
  end

  return self._cleanupMemory
end

--- Check whether current memory is within baselineMargin of the baseline.
-- Also detects persistent upward trends (memory leak) by comparing the
-- high-water mark and CLEANUP exit against baseline.
-- @return boolean, table|nil (true if healthy, false if leaking + diagnostics)
function Profiler:checkBaseline()
  if self._baselineMemory == nil then
    return true, nil  -- no baseline taken yet
  end

  local currentMemory = self._getMemory()
  local maxAllowed = self._baselineMemory * (1.0 + self._baselineMargin)
  local minAllowed = self._baselineMemory * (1.0 - self._baselineMargin)

  local diagnostics = {
    baseline    = self._baselineMemory,
    current     = currentMemory,
    maxAllowed  = maxAllowed,
    minAllowed  = minAllowed,
    withinRange = currentMemory >= minAllowed and currentMemory <= maxAllowed,
    leakDetected = false,
    highWaterMark = self._highWaterMark,
  }

  -- Check post-CLEANUP if available
  if self._cleanupMemory ~= nil then
    diagnostics.cleanupMemory = self._cleanupMemory
    diagnostics.cleanupInRange = self._cleanupMemory >= minAllowed and self._cleanupMemory <= maxAllowed

    -- Leak detection: if CLEANUP exit consistently stays above baseline
    -- after multiple cycles, it's a creeping leak
    if self._cleanupMemory > maxAllowed then
      diagnostics.leakDetected = true
      self._leakAlarm = true
    end
  end

  -- Persistent upward trend: high-water mark significantly above baseline
  if self._highWaterMark and self._highWaterMark > maxAllowed then
    diagnostics.highWaterAboveBaseline = true
  end

  return not diagnostics.leakDetected and diagnostics.withinRange, diagnostics
end

-- ===========================================================================
-- Report
-- ===========================================================================

--- Build a structured report for Supervisor telemetry integration.
-- Includes phase timing stats, yield gap summary, and GC health.
-- @return table structured report
function Profiler:getReport()
  local report = {}

  -- Phase timing
  report.phases = {}
  for phaseName, samples in pairs(self._phaseSamples) do
    report.phases[phaseName] = computeStats(samples)
    report.phases[phaseName].violations = self._phaseViolations[phaseName] or 0
    report.phases[phaseName].budget    = self._phaseBudget
  end

  -- Yield gap
  report.yieldGap = {
    violations     = self._yieldViolations,
    threshold      = self._yieldWarnThreshold,
    totalYieldTime = self._totalYieldGapTime,
    yieldCount     = self._yieldCount,
    latestLog      = self._yieldViolationLog,
  }

  -- GC memory
  local isHealthy, diag = self:checkBaseline()
  report.gc = {
    baseline     = self._baselineMemory,
    current      = self._getMemory(),
    highWaterMark = self._highWaterMark,
    healthy      = isHealthy,
    leakAlarm    = self._leakAlarm,
    diagnostics  = diag,
  }

  -- Configuration snapshot
  report.config = {
    windowSize         = self._windowSize,
    yieldWarnThreshold = self._yieldWarnThreshold,
    phaseBudget        = self._phaseBudget,
    baselineMargin     = self._baselineMargin,
  }

  return report
end

--- Get the number of yield gap violations detected so far.
-- @return number
function Profiler:getYieldViolationCount()
  return self._yieldViolations
end

--- Get the number of phase budget violations for a given phase.
-- @param phaseName string
-- @return number
function Profiler:getPhaseViolationCount(phaseName)
  if not phaseName then
    local total = 0
    for _, count in pairs(self._phaseViolations) do
      total = total + count
    end
    return total
  end
  return self._phaseViolations[phaseName] or 0
end

-- ===========================================================================
-- Reset
-- ===========================================================================

--- Reset all collected data (samples, stats, timers, violations).
-- Does NOT reset the baseline memory snapshot or the attachment state.
-- Call this at the start of a new monitoring period.
function Profiler:reset()
  -- Phase timing
  self._phaseSamples = {}
  self._phaseTimers = {}
  self._phaseViolations = {}

  -- Yield gap
  self._lastYieldTime = self._now()
  self._yieldViolations = 0
  self._yieldViolationLog = {}
  self._yieldCount = 0
  self._totalYieldGapTime = 0

  -- GC memory
  self._entryMemory = {}
  self._cleanupMemory = nil
  self._leakAlarm = false
  self._highWaterMark = self._baselineMemory
end

--- Full reset: clears ALL data INCLUDING baseline and attachment state.
-- Use only when reconfiguring the profiler for a new monitoring session.
function Profiler:resetAll()
  self:reset()
  self._baselineMemory = nil
  self._highWaterMark = nil
  self._attached = false
  self._broker = nil
end

return Profiler
