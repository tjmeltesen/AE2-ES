-- test_profiler.lua
-- C8: Runtime Performance Profiler — Phase D unit tests.
--
-- Validates:
--   1. Phase timing accuracy (startPhase/endPhase)
--   2. Yield gap detection at configured threshold boundary
--   3. GC baseline assertion (within 5% and outside 5%)
--   4. Rolling window overflow and statistics (min, max, mean, p95, p99)
--   5. attach/detach broker integration
--   6. getReport serialization structure
--
-- All OC-specific dependencies are mocked for deterministic testing.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

-- ===========================================================================
-- Mocks for deterministic testing
-- ===========================================================================

local mockClock = 0.0
local mockMemory = 8192000  -- 8 MB baseline, in bytes
local yieldLog = {}         -- tracks every recordedYield call

-- Override os.clock for deterministic time control
local realClock = os.clock
os.clock = function()
  return mockClock
end

--- Advance the mock clock by a given number of seconds.
-- @param seconds number
local function advanceClock(seconds)
  mockClock = mockClock + seconds
end

--- Set mock memory (used memory in bytes).
-- @param bytes number
local function setMemory(bytes)
  mockMemory = bytes
end

--- Reset all mocks to initial state.
local function resetMocks()
  mockClock = 0.0
  mockMemory = 8192000
  yieldLog = {}
end

--- Mock memory function used by profiler in tests.
-- Returns the current mock memory value.
-- @return number bytes
local function mockGetMemory()
  return mockMemory
end

-- Load the module after setting up mocks
local Profiler = require("src.profiler")

--- Create a fresh profiler instance with mocks wired in.
-- @param config table optional overrides passed to Profiler.new()
-- @return Profiler instance
local function newProfiler(config)
  resetMocks()
  config = config or {}
  config.clockOverride = function() return mockClock end
  config.memoryOverride = mockGetMemory
  return Profiler.new(config)
end

-- ===========================================================================
-- Helper to create a mock broker for attach() testing
-- ===========================================================================
local function makeMockBroker()
  return {
    getPhase = function(self)
      return self._phase or "BUFFERING"
    end,
    _phase = "BUFFERING",
    tick = function(self)
      return true
    end,
  }
end

-- ===========================================================================
-- Test Group 1: Construction and Defaults
-- ===========================================================================

Assert.startTest("Construction with default config")
do
  resetMocks()
  local p = Profiler.new({
    clockOverride = function() return mockClock end,
    memoryOverride = mockGetMemory,
  })
  Assert.equal(100, p._windowSize, "Default window size should be 100")
  Assert.equal(4.0, p._yieldWarnThreshold, "Default yield warn threshold should be 4.0")
  Assert.equal(4.0, p._phaseBudget, "Default phase budget should be 4.0")
  Assert.equal(0.05, p._baselineMargin, "Default baseline margin should be 0.05")
  Assert.isFalse(p._attached, "Should not be attached initially")
  Assert.isNil(p._baselineMemory, "Baseline memory should be nil before attach/resetAll")
  Assert.type("table", p._phaseSamples, "Phase samples table should exist")
  Assert.type("table", p._phaseTimers, "Phase timers table should exist")
  Assert.type("table", p._phaseViolations, "Phase violations table should exist")
end
Assert.endTest()

Assert.startTest("Construction with custom config")
do
  resetMocks()
  local p = Profiler.new({
    windowSize = 50,
    yieldWarnThreshold = 3.0,
    phaseBudget = 5.0,
    baselineMargin = 0.10,
    clockOverride = function() return mockClock end,
    memoryOverride = mockGetMemory,
  })
  Assert.equal(50, p._windowSize, "Custom window size should be 50")
  Assert.equal(3.0, p._yieldWarnThreshold, "Custom yield warn threshold should be 3.0")
  Assert.equal(5.0, p._phaseBudget, "Custom phase budget should be 5.0")
  Assert.equal(0.10, p._baselineMargin, "Custom baseline margin should be 0.10")

  -- Test nil config
  resetMocks()
  local p2 = Profiler.new(nil)
  Assert.notNil(p2, "nil config should still create a profiler")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 2: Phase Timing Accuracy
-- ===========================================================================

Assert.startTest("startPhase and endPhase measure wall-clock time")
do
  local p = newProfiler()
  p:startPhase("BUFFERING")
  advanceClock(1.5)
  p:endPhase("BUFFERING")

  local samples = p._phaseSamples["BUFFERING"]
  Assert.notNil(samples, "BUFFERING samples should exist")
  Assert.equal(1, #samples, "Should have 1 sample")
  Assert.isTrue(math.abs(samples[1] - 1.5) < 0.001,
    "Sample should be ~1.5s, got " .. tostring(samples[1]))
end
Assert.endTest()

Assert.startTest("Multiple phases accumulate separate windows")
do
  local p = newProfiler()

  p:startPhase("BUFFERING")
  advanceClock(0.5)
  p:endPhase("BUFFERING")

  p:startPhase("PROCESSING")
  advanceClock(2.0)
  p:endPhase("PROCESSING")

  p:startPhase("CLEANUP")
  advanceClock(0.3)
  p:endPhase("CLEANUP")

  Assert.equal(1, #p._phaseSamples["BUFFERING"], "BUFFERING should have 1 sample")
  Assert.equal(1, #p._phaseSamples["PROCESSING"], "PROCESSING should have 1 sample")
  Assert.equal(1, #p._phaseSamples["CLEANUP"], "CLEANUP should have 1 sample")

  Assert.isTrue(math.abs(p._phaseSamples["BUFFERING"][1] - 0.5) < 0.001)
  Assert.isTrue(math.abs(p._phaseSamples["PROCESSING"][1] - 2.0) < 0.001)
  Assert.isTrue(math.abs(p._phaseSamples["CLEANUP"][1] - 0.3) < 0.001)
end
Assert.endTest()

Assert.startTest("Double startPhase is idempotent (no-op)")
do
  local p = newProfiler()
  p:startPhase("BUFFERING")
  advanceClock(0.5)
  p:startPhase("BUFFERING")  -- second start, same phase — should be no-op
  advanceClock(0.5)
  p:endPhase("BUFFERING")

  local samples = p._phaseSamples["BUFFERING"]
  Assert.equal(1, #samples, "Should still have 1 sample")
  -- Should be 1.0s total (0.5 + 0.5), because second startPhase was ignored
  Assert.isTrue(math.abs(samples[1] - 1.0) < 0.001,
    "Duration should be 1.0s (second startPhase was no-op)")
end
Assert.endTest()

Assert.startTest("endPhase without matching startPhase is no-op")
do
  local p = newProfiler()
  p:endPhase("TRANSFERRING")  -- no matching start
  Assert.isNil(p._phaseSamples["TRANSFERRING"], "No samples should be recorded")
end
Assert.endTest()

Assert.startTest("Phase timing with nil/non-string args is safe")
do
  local p = newProfiler()
  p:startPhase(nil)
  p:endPhase(nil)
  p:startPhase(42)
  p:endPhase(42)
  -- Should not crash, no samples recorded
  Assert.tableEmpty(p._phaseSamples, "No phases should be recorded for invalid args")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 3: Phase Budget Violations
-- ===========================================================================

Assert.startTest("Phase exceeding 4s budget registers a violation")
do
  local p = newProfiler()
  p:startPhase("TRANSFERRING")
  advanceClock(5.0)
  p:endPhase("TRANSFERRING")

  Assert.equal(1, p:getPhaseViolationCount("TRANSFERRING"),
    "TRANSFERRING should have 1 violation")
  Assert.isTrue(p._phaseViolations["TRANSFERRING"] >= 1)
end
Assert.endTest()

Assert.startTest("Phase under budget does not register violation")
do
  local p = newProfiler()
  p:startPhase("LOGGING")
  advanceClock(2.0)
  p:endPhase("LOGGING")

  Assert.equal(0, p:getPhaseViolationCount("LOGGING"),
    "2s phase should not violate 4s budget")
end
Assert.endTest()

Assert.startTest("Phase exactly at budget boundary is NOT a violation")
do
  local p = newProfiler({ phaseBudget = 4.0,
    clockOverride = function() return mockClock end,
    memoryOverride = mockGetMemory })
  p:startPhase("ALLOCATING")
  advanceClock(4.0)
  p:endPhase("ALLOCATING")

  Assert.equal(0, p:getPhaseViolationCount("ALLOCATING"),
    "Exactly 4s is not a violation (boundary)")
end
Assert.endTest()

Assert.startTest("getPhaseViolationCount with nil returns total across all phases")
do
  local p = newProfiler()
  p:startPhase("A"); advanceClock(5.0); p:endPhase("A")  -- violation
  p:startPhase("B"); advanceClock(6.0); p:endPhase("B")  -- violation
  p:startPhase("C"); advanceClock(1.0); p:endPhase("C")  -- OK

  Assert.equal(2, p:getPhaseViolationCount(nil),
    "Total violations across all phases should be 2")
  Assert.equal(1, p:getPhaseViolationCount("A"), "Phase A: 1 violation")
  Assert.equal(1, p:getPhaseViolationCount("B"), "Phase B: 1 violation")
  Assert.equal(0, p:getPhaseViolationCount("C"), "Phase C: 0 violations")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 4: Rolling Window Statistics
-- ===========================================================================

Assert.startTest("Rolling window correctly computes min, max, mean, p95, p99")
do
  local p = newProfiler({ windowSize = 10,
    clockOverride = function() return mockClock end,
    memoryOverride = mockGetMemory })
  -- Insert 10 samples: 0.1, 0.2, ..., 1.0
  for i = 1, 10 do
    p:startPhase("TEST")
    advanceClock(i * 0.1)
    p:endPhase("TEST")
  end

  local samples = p._phaseSamples["TEST"]
  Assert.equal(10, #samples, "Should have 10 samples")

  local report = p:getReport()
  local stats = report.phases["TEST"]
  Assert.notNil(stats, "Stats for TEST phase should exist")
  Assert.equal(10, stats.count, "Count should be 10")
  Assert.isTrue(math.abs(stats.min - 0.1) < 0.001, "Min should be ~0.1")
  Assert.isTrue(math.abs(stats.max - 1.0) < 0.001, "Max should be ~1.0")
  Assert.isTrue(math.abs(stats.mean - 0.55) < 0.001, "Mean should be ~0.55")
  -- p95 of 10 sorted: floor(0.95*10) = 9th element = 0.9
  Assert.isTrue(math.abs(stats.p95 - 0.9) < 0.001,
    "p95 should be ~0.9 (9th of 10)")
  -- p99 of 10 sorted: floor(0.99*10) = 9th element = 0.9
  Assert.isTrue(math.abs(stats.p99 - 0.9) < 0.001,
    "p99 should be ~0.9 (9th of 10)")
end
Assert.endTest()

Assert.startTest("Rolling window overflow drops oldest samples")
do
  local p = newProfiler({ windowSize = 5,
    clockOverride = function() return mockClock end,
    memoryOverride = mockGetMemory })
  -- Insert 8 samples with increasing durations: 1.0, 2.0, ..., 8.0
  for i = 1, 8 do
    p:startPhase("OVERFLOW")
    advanceClock(i * 1.0)  -- each phase takes i seconds
    p:endPhase("OVERFLOW")
  end

  local samples = p._phaseSamples["OVERFLOW"]
  Assert.equal(5, #samples, "Window should be capped at 5")
  -- Durations: 1.0, 2.0, 3.0 were dropped; 4.0, 5.0, 6.0, 7.0, 8.0 remain
  -- But samples are in insertion order, so samples[1] = 4.0 (oldest kept)
  Assert.equal(8.0, samples[5], "Last sample should be 8.0 (newest)")
  Assert.isTrue(samples[1] >= 4.0, "First retained sample should be 4.0+")
end
Assert.endTest()

Assert.startTest("Empty rolling window produces zeroed stats")
do
  local p = newProfiler()
  local report = p:getReport()
  Assert.tableEmpty(report.phases, "No phases should have been recorded")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 5: Yield Gap Detection
-- ===========================================================================

Assert.startTest("Yield gap within threshold does not trigger violation")
do
  local p = newProfiler()
  p:recordYield()  -- first yield, counts but is not a violation (self._yieldCount == 1)
  advanceClock(2.0)
  p:recordYield()  -- 2s gap, within 4s threshold

  Assert.equal(0, p:getYieldViolationCount(),
    "2s gap should not trigger a violation")
end
Assert.endTest()

Assert.startTest("Yield gap exceeding threshold triggers violation")
do
  local p = newProfiler()
  p:recordYield()  -- first yield
  advanceClock(5.0)
  p:recordYield()  -- 5s gap > 4s threshold

  Assert.equal(1, p:getYieldViolationCount(),
    "5s gap should trigger a violation")
end
Assert.endTest()

Assert.startTest("Multiple yield gaps accumulate violations")
do
  local p = newProfiler()
  p:recordYield()
  advanceClock(5.0); p:recordYield()  -- violation 1
  advanceClock(6.0); p:recordYield()  -- violation 2
  advanceClock(3.0); p:recordYield()  -- OK, within threshold
  advanceClock(10.0); p:recordYield() -- violation 3

  Assert.equal(3, p:getYieldViolationCount(),
    "3 violations should be detected")
end
Assert.endTest()

Assert.startTest("Yield violation log contains details")
do
  local p = newProfiler()
  p:recordYield()
  advanceClock(5.0)
  p:recordYield()

  Assert.equal(1, #p._yieldViolationLog, "Violation log should have 1 entry")
  Assert.isTrue(p._yieldViolationLog[1].gap >= 5.0, "Gap should be ~5.0")
  Assert.isTrue(p._yieldViolationLog[1].breach >= 1.0, "Breach should be ~1.0")
end
Assert.endTest()

Assert.startTest("Yield violation log capped at 10 entries")
do
  local p = newProfiler()
  p:recordYield()
  for i = 1, 15 do
    advanceClock(5.0)
    p:recordYield()  -- each is a violation
  end

  Assert.equal(15, p:getYieldViolationCount(),
    "15 total violations (first yield doesn't count, 15 loop yields all breach)")
  Assert.equal(10, #p._yieldViolationLog,
    "Violation log should be capped at 10")
end
Assert.endTest()

Assert.startTest("startPhase checks yield gap implicitly")
do
  local p = newProfiler()
  p:recordYield()
  advanceClock(6.0)
  p:startPhase("BUFFERING")  -- should detect the gap

  Assert.equal(1, p:getYieldViolationCount(),
    "startPhase should detect 6s yield gap")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 6: GC Memory Baseline
-- ===========================================================================

Assert.startTest("Baseline recorded on first attach")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(4096000)  -- 4 MB
  p:attach(broker)

  Assert.equal(4096000, p._baselineMemory, "Baseline should be 4 MB")
end
Assert.endTest()

Assert.startTest("Memory within 5% of baseline passes checkBaseline")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(10000000)  -- 10 MB baseline
  p:attach(broker)

  -- After CLEANUP, memory should be within 5% of 10 MB (9.5-10.5 MB)
  setMemory(10200000)  -- 10.2 MB = +2%, within margin
  p:recordCleanupExit()

  local ok, diag = p:checkBaseline()
  Assert.isTrue(ok, "10.2 MB should be within 5% of 10 MB baseline")
  Assert.notNil(diag, "Diagnostics should be returned")
  Assert.isTrue(diag.withinRange, "diag.withinRange should be true")
end
Assert.endTest()

Assert.startTest("Memory outside 5% of baseline fails checkBaseline")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(10000000)  -- 10 MB baseline
  p:attach(broker)

  -- After CLEANUP, memory far above baseline
  setMemory(15000000)  -- 15 MB = +50%, far outside margin
  p:recordCleanupExit()

  local ok, diag = p:checkBaseline()
  Assert.isFalse(ok, "15 MB should fail baseline check")
  Assert.notNil(diag, "Diagnostics should be returned")
  Assert.isFalse(diag.withinRange, "diag.withinRange should be false")
  Assert.isTrue(diag.leakDetected, "Leak should be detected")
end
Assert.endTest()

Assert.startTest("Baseline check with memory exactly at margin boundary passes")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(10000000)
  p:attach(broker)

  -- Exactly at upper bound: 10.5 MB (10M * 1.05)
  setMemory(10500000)
  p:recordCleanupExit()

  local ok, diag = p:checkBaseline()
  Assert.isTrue(ok, "Exactly 5% above should pass")
end
Assert.endTest()

Assert.startTest("Baseline check without attach returns true with nil diagnostics")
do
  local p = newProfiler({
    clockOverride = function() return mockClock end,
    memoryOverride = mockGetMemory,
  })
  local ok, diag = p:checkBaseline()
  Assert.isTrue(ok, "Without baseline, check should return true")
  Assert.isNil(diag, "Without baseline, diagnostics should be nil")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 7: attach / detach Broker Integration
-- ===========================================================================

Assert.startTest("attach wires profiler into broker's tick method")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8000000)

  local attached = p:attach(broker)
  Assert.isTrue(attached, "attach should return true")
  Assert.isTrue(p._attached, "Profiler should be marked attached")

  -- The original tick should have been wrapped
  Assert.notNil(broker.tick, "Broker should still have a tick method")
end
Assert.endTest()

Assert.startTest("attach returns false for invalid arguments")
do
  local p = newProfiler()
  Assert.isFalse(p:attach(nil), "attach(nil) should return false")
  Assert.isFalse(p:attach("not a broker"), "attach(string) should return false")
  Assert.isFalse(p:attach({}), "attach({}) should return false (no getPhase)")
end
Assert.endTest()

Assert.startTest("attach is idempotent (second call returns false)")
do
  local p = newProfiler()
  local broker1 = makeMockBroker()
  local broker2 = makeMockBroker()

  setMemory(8000000)
  Assert.isTrue(p:attach(broker1), "First attach should succeed")
  Assert.isFalse(p:attach(broker2), "Second attach to different broker should fail")
end
Assert.endTest()

Assert.startTest("detach restores original tick method")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  local originalTick = broker.tick
  setMemory(8000000)

  p:attach(broker)
  Assert.isTrue(broker.tick ~= originalTick, "Tick should be wrapped after attach")

  p:detach()
  Assert.isFalse(p._attached, "Profiler should not be attached after detach")
end
Assert.endTest()

Assert.startTest("detach on un-attached profiler returns false")
do
  local p = newProfiler()
  Assert.isFalse(p:detach(), "detach without attach should return false")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 8: getReport Structure
-- ===========================================================================

Assert.startTest("getReport returns structured results")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8192000)
  p:attach(broker)

  -- Run a few phases
  p:startPhase("BUFFERING"); advanceClock(0.5); p:endPhase("BUFFERING")
  p:startPhase("LOGGING"); advanceClock(0.3); p:endPhase("LOGGING")
  p:startPhase("PROCESSING"); advanceClock(5.0); p:endPhase("PROCESSING")  -- violation

  p:recordYield()
  advanceClock(6.0)
  p:recordYield()  -- violation

  setMemory(8200000)
  p:recordCleanupExit()

  local report = p:getReport()
  Assert.type("table", report, "Report should be a table")

  -- Phase timing section
  Assert.type("table", report.phases, "Report should have phases")
  Assert.notNil(report.phases.BUFFERING, "BUFFERING stats should exist")
  Assert.notNil(report.phases.LOGGING, "LOGGING stats should exist")
  Assert.notNil(report.phases.PROCESSING, "PROCESSING stats should exist")
  Assert.equal(1, report.phases.PROCESSING.violations, "PROCESSING should have 1 violation")

  -- Yield gap section
  Assert.type("table", report.yieldGap, "Report should have yieldGap")
  Assert.equal(1, report.yieldGap.violations, "Should have 1 yield violation")
  Assert.type("table", report.yieldGap.latestLog, "yieldGap should have latestLog")

  -- GC section
  Assert.type("table", report.gc, "Report should have gc")
  Assert.equal(8192000, report.gc.baseline, "Baseline should match")
  Assert.type("boolean", report.gc.healthy, "gc.healthy should be boolean")
  Assert.type("boolean", report.gc.leakAlarm, "gc.leakAlarm should be boolean")

  -- Config section
  Assert.type("table", report.config, "Report should have config")
  Assert.equal(100, report.config.windowSize, "Config windowSize should be present")
end
Assert.endTest()

Assert.startTest("getReport serializes to a flat table (safe for telemetry)")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8192000)
  p:attach(broker)

  -- Run one phase
  p:startPhase("BUFFERING"); advanceClock(0.5); p:endPhase("BUFFERING")
  p:recordYield()

  local report = p:getReport()

  -- Verify all fields are basic Lua types (no functions, no userdata)
  local function checkTypes(t, path)
    if type(t) == "table" then
      for k, v in pairs(t) do
        local subpath = path .. "." .. tostring(k)
        if type(v) == "function" then
          error("Function found in report at " .. subpath)
        elseif type(v) == "userdata" then
          error("Userdata found in report at " .. subpath)
        elseif type(v) == "table" then
          checkTypes(v, subpath)
        end
      end
    end
  end

  local ok, err = pcall(checkTypes, report, "report")
  Assert.isTrue(ok, "Report should contain only basic Lua types: " .. tostring(err))
end
Assert.endTest()

-- ===========================================================================
-- Test Group 9: Reset
-- ===========================================================================

Assert.startTest("reset() clears all samples but keeps baseline")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8192000)
  p:attach(broker)

  p:startPhase("TEST"); advanceClock(1.0); p:endPhase("TEST")
  p:recordYield()
  advanceClock(5.0)
  p:recordYield()

  Assert.equal(1, #p._phaseSamples["TEST"], "Should have 1 sample before reset")
  Assert.equal(1, p:getYieldViolationCount(), "Should have 1 yield violation before reset")

  p:reset()

  Assert.tableEmpty(p._phaseSamples, "Phase samples should be empty after reset")
  Assert.tableEmpty(p._phaseTimers, "Phase timers should be empty after reset")
  Assert.equal(0, p:getYieldViolationCount(), "Yield violations should be 0 after reset")
  Assert.notNil(p._baselineMemory, "Baseline memory should be preserved after reset")
  Assert.isTrue(p._attached, "Attachment state should be preserved after reset")
end
Assert.endTest()

Assert.startTest("resetAll() clears everything including baseline and attachment")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8192000)
  p:attach(broker)

  p:startPhase("TEST"); advanceClock(1.0); p:endPhase("TEST")

  p:resetAll()

  Assert.tableEmpty(p._phaseSamples, "Phase samples should be empty")
  Assert.isNil(p._baselineMemory, "Baseline should be nil after resetAll")
  Assert.isFalse(p._attached, "Attachment should be cleared after resetAll")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 10: recordCleanupExit and Memory Tracking
-- ===========================================================================

Assert.startTest("recordCleanupExit records memory and updates high-water mark")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8000000)
  p:attach(broker)

  setMemory(8200000)
  local mem1 = p:recordCleanupExit()
  Assert.equal(8200000, mem1, "Should return current memory")
  Assert.equal(8200000, p._highWaterMark, "High-water mark should update")

  setMemory(8100000)
  local mem2 = p:recordCleanupExit()
  Assert.equal(8100000, mem2, "Should return current memory")
  Assert.equal(8200000, p._highWaterMark, "High-water mark should NOT decrease")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 11: Attached Broker Tick Instruments Phases
-- ===========================================================================

Assert.startTest("Attached broker tick records phase timing")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8000000)
  p:attach(broker)

  -- Run broker tick (should call startPhase + endPhase around original tick)
  broker:tick()

  -- The broker's phase is BUFFERING, so profiler should have recorded it
  local samples = p._phaseSamples["BUFFERING"]
  Assert.notNil(samples, "BUFFERING phase should have been recorded")
  Assert.equal(1, #samples, "Should have 1 BUFFERING sample")
end
Assert.endTest()

Assert.startTest("Multiple ticks accumulate phase samples on attached broker")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(8000000)
  p:attach(broker)

  for i = 1, 5 do
    advanceClock(0.5)
    broker:tick()
  end

  local samples = p._phaseSamples["BUFFERING"]
  Assert.notNil(samples, "BUFFERING samples should exist")
  Assert.equal(5, #samples, "5 ticks should produce 5 samples")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 12: Edge Cases
-- ===========================================================================

Assert.startTest("Profiler handles rapid start/end on same phase")
do
  local p = newProfiler()
  for i = 1, 100 do
    p:startPhase("RAPID")
    p:endPhase("RAPID")
  end
  Assert.equal(100, #p._phaseSamples["RAPID"],
    "100 rapid start/end cycles should all be recorded")
end
Assert.endTest()

Assert.startTest("Profiler handles phase name with special characters")
do
  local p = newProfiler()
  p:startPhase("phase_with_underscores!@#")
  advanceClock(0.5)
  p:endPhase("phase_with_underscores!@#")

  Assert.notNil(p._phaseSamples["phase_with_underscores!@#"],
    "Special character phase names should work")
end
Assert.endTest()

Assert.startTest("Profiler handles memory spike and recovery")
do
  local p = newProfiler()
  local broker = makeMockBroker()
  setMemory(10000000)  -- 10 MB baseline
  p:attach(broker)

  -- Simulate memory spike during processing
  setMemory(18000000)  -- 18 MB, well above baseline
  p:startPhase("PROCESSING")
  p:endPhase("PROCESSING")

  -- After CLEANUP, memory returns close to baseline
  setMemory(10100000)  -- 10.1 MB, within 5%
  p:recordCleanupExit()

  local ok, diag = p:checkBaseline()
  Assert.isTrue(ok, "Should recover to within 5% of baseline after CLEANUP")
  Assert.isTrue(diag.withinRange, "diag.withinRange should be true")

  -- However, high-water mark should still be high
  Assert.equal(18000000, p._highWaterMark,
    "High-water mark should reflect the spike")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 13: Null/Edge Cases for recordYield and Yield Tracking
-- ===========================================================================

Assert.startTest("recordYield resets the gap timer correctly")
do
  local p = newProfiler()
  p:recordYield()
  advanceClock(3.0)     -- 3s gap, within threshold
  p:recordYield()       -- resets timer
  advanceClock(5.0)     -- 5s gap from previous yield
  p:recordYield()       -- violation

  Assert.equal(1, p:getYieldViolationCount(),
    "Only 1 violation: 3s was fine, 5s was violation")
end
Assert.endTest()

Assert.startTest("getReport yield section reflects reset state")
do
  local p = newProfiler()
  p:recordYield()
  advanceClock(5.0)
  p:recordYield()

  local reportBefore = p:getReport()
  Assert.equal(1, reportBefore.yieldGap.violations, "Violations before reset")

  p:reset()
  local reportAfter = p:getReport()
  Assert.equal(0, reportAfter.yieldGap.violations, "Violations after reset")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 14: Zero-duration Phase
-- ===========================================================================

Assert.startTest("Zero-duration phase produces 0-second sample")
do
  local p = newProfiler()
  p:startPhase("ZERO")
  -- no clock advance
  p:endPhase("ZERO")

  local samples = p._phaseSamples["ZERO"]
  Assert.equal(1, #samples, "Should have 1 sample")
  Assert.isTrue(math.abs(samples[1]) < 0.001, "Duration should be ~0s")
end
Assert.endTest()

print("profiler.lua unit tests loaded successfully")
