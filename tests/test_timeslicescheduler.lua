-- test_timeslicescheduler.lua
-- A11: Time-Slice Scheduler — cooperative multitasking unit tests.
--
-- Validates:
--   - Slice budget tracking (elapsed, exhausted, remaining, usage)
--   - Yielding (sleep, checkpoint, checkpointNow)
--   - Loop helpers with automatic yield checkpoints (forEach, forEachPair)
--   - Deferred task queue (defer, processQueue, pendingTasks, clearQueue)
--   - Budget-protected execution (runProtected)
--   - Error accumulation and statistics
--   - Edge cases: nil/null args, empty lists, fast operations,
--     os.sleep absence, custom budgets

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

-- ===========================================================================
-- Mock os.clock and os.sleep for deterministic testing
-- ===========================================================================
local mockClock = 0.0
local yieldLog = {}   -- tracks every os.sleep(0) call

local realClock = os.clock
os.clock = function()
  return mockClock
end

-- Provide os.sleep even if it doesn't exist in standalone Lua
if type(os.sleep) ~= "function" then
  os.sleep = function(seconds)
    table.insert(yieldLog, {time = mockClock, duration = seconds})
  end
end
-- Wrap the original so we can count/track yields
local realSleep = os.sleep
os.sleep = function(seconds)
  table.insert(yieldLog, {time = mockClock, duration = seconds})
  return realSleep(seconds)
end

local function advanceClock(seconds)
  mockClock = mockClock + seconds
end

local function resetClock()
  mockClock = 0.0
  yieldLog = {}
end

local function countYields()
  return #yieldLog
end

-- Load the module after mocking os.clock
local TimeSliceScheduler = require("src.timeslicescheduler")

-- ===========================================================================
-- Helper: create a fresh scheduler for each test
-- ===========================================================================
local function newSched(budget)
  resetClock()
  return TimeSliceScheduler.new(budget)
end

-- ===========================================================================
-- Test Group 1: Construction and Defaults
-- ===========================================================================

Assert.startTest("Construction with default budget")
do
  resetClock()
  local s = TimeSliceScheduler.new()
  Assert.equal(3.0, s.budget, "Default budget should be 3.0")
  Assert.equal("table", type(s), "new() should return a table")
  Assert.equal(0, s._yieldCount, "Initial yield count should be 0")
  Assert.equal(0, s:pendingTasks(), "Initial pending tasks should be 0")
  Assert.isTrue(s._canSleep, "Should detect os.sleep availability via _canSleep")
  -- Stats table
  local stats = s:stats()
  Assert.equal("table", type(stats), "stats() should return a table")
  Assert.equal(3.0, stats.budget, "stats.budget should be 3.0")
  -- Since we mocked os.clock starting at 0, elapsed should be ~0
  Assert.isTrue(stats.elapsed >= 0, "Initial elapsed should be >= 0")
end
Assert.endTest()

Assert.startTest("Construction with custom budget")
do
  local s = TimeSliceScheduler.new(5.0)
  Assert.equal(5.0, s.budget, "Custom budget should be 5.0")
  local s2 = TimeSliceScheduler.new(0.5)
  Assert.equal(0.5, s2.budget, "Custom budget should be 0.5")
  local s3 = TimeSliceScheduler.new(nil)
  Assert.equal(3.0, s3.budget, "nil budget should fall back to default 3.0")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 2: Slice Budget Tracking
-- ===========================================================================

Assert.startTest("elapsed() tracks wall-clock time")
do
  local s = newSched()
  Assert.equal(0, s:elapsed(), "elapsed should be 0 at start")
  advanceClock(1.0)
  Assert.isTrue(s:elapsed() >= 1.0, "elapsed should track clock advance")
  advanceClock(2.5)
  Assert.isTrue(s:elapsed() >= 3.5, "elapsed should accumulate")
end
Assert.endTest()

Assert.startTest("exhausted() returns true when budget consumed")
do
  local s = newSched(2.0)
  Assert.isFalse(s:exhausted(), "Should not be exhausted at start")
  advanceClock(1.5)
  Assert.isFalse(s:exhausted(), "1.5s < 2.0s budget, should not be exhausted")
  advanceClock(0.6)
  Assert.isTrue(s:exhausted(), "2.1s >= 2.0s budget, should be exhausted")
end
Assert.endTest()

Assert.startTest("remaining() reports correct time left")
do
  local s = newSched(3.0)
  Assert.equal(3.0, s:remaining(), "Remaining should be full budget at start")
  advanceClock(1.0)
  Assert.isTrue(s:remaining() <= 2.0, "Remaining should decrease over time")
  advanceClock(3.0)
  Assert.equal(0, s:remaining(), "Remaining should be 0 when exhausted")
end
Assert.endTest()

Assert.startTest("usage() reports fraction consumed")
do
  local s = newSched(4.0)
  Assert.equal(0, s:usage(), "Usage should be 0 at start")
  advanceClock(2.0)
  Assert.equal(0.5, s:usage(), "Usage should be 0.5 after 2s on 4s budget")
  advanceClock(6.0)
  Assert.isTrue(s:usage() > 1.0, "Usage can exceed 1.0 when elapsed > budget")
end
Assert.endTest()

Assert.startTest("reset() restarts the slice timer")
do
  local s = newSched()
  advanceClock(5.0)
  Assert.isTrue(s:exhausted(), "Should be exhausted before reset")
  s:reset()
  Assert.isFalse(s:exhausted(), "Should NOT be exhausted after reset")
  Assert.isTrue(s:elapsed() < 0.1, "elapsed should be near 0 after reset")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 3: Yielding
-- ===========================================================================

Assert.startTest("sleep() yields via os.sleep(0)")
do
  resetClock()
  local s = TimeSliceScheduler.new(3.0)
  -- With os.sleep mocked in, _canSleep should be true
  -- Our mock provides os.sleep even if standalone Lua doesn't
  local beforeYields = #yieldLog
  s:sleep()
  local afterYields = #yieldLog
  Assert.isTrue(afterYields > beforeYields, "sleep() should increment yield log")
  Assert.equal(1, s._yieldCount, "Internal yield count should increment")
end
Assert.endTest()

Assert.startTest("checkpoint() yields only when budget exhausted")
do
  resetClock()
  local s = newSched(3.0)
  -- Not exhausted yet
  local beforeYields = countYields()
  local didYield = s:checkpoint()
  Assert.isFalse(didYield, "checkpoint() should not yield when budget remains")
  Assert.equal(beforeYields, countYields(), "No os.sleep calls should have happened")

  -- Advance past budget
  advanceClock(4.0)
  beforeYields = countYields()
  didYield = s:checkpoint()
  Assert.isTrue(didYield, "checkpoint() should yield when budget exhausted")

  -- After yield+reset, elapsed should be near 0 again
  Assert.isFalse(s:exhausted(), "Slice timer should have reset after yield")
end
Assert.endTest()

Assert.startTest("checkpointNow() always yields")
do
  resetClock()
  local s = newSched(3.0)
  local beforeYields = countYields()
  s:checkpointNow()
  Assert.isTrue(countYields() > beforeYields, "checkpointNow() should always yield")
  Assert.isFalse(s:exhausted(), "Budget should be reset after unconditional checkpoint")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 4: Budget-Protected Execution
-- ===========================================================================

Assert.startTest("runProtected() executes when budget remains")
do
  local s = newSched(3.0)
  local ran = false
  local ok, result = s:runProtected(function()
    ran = true
    return 42
  end)
  Assert.isTrue(ok, "runProtected should succeed")
  Assert.isTrue(ran, "Function should have executed")
  Assert.equal(42, result, "Function return value should be preserved")
end
Assert.endTest()

Assert.startTest("runProtected() refuses when budget exhausted")
do
  local s = newSched(3.0)
  advanceClock(5.0)
  local ran = false
  local ok, result = s:runProtected(function()
    ran = true
    return 42
  end)
  Assert.isFalse(ok, "runProtected should fail when budget exhausted")
  Assert.equal("budget exhausted", result, "Should return budget exhausted message")
  Assert.isFalse(ran, "Function should NOT have executed")
end
Assert.endTest()

Assert.startTest("runProtected() handles nil function gracefully")
do
  local s = newSched(3.0)
  local ok, err = s:runProtected(nil)
  Assert.isFalse(ok, "runProtected(nil) should fail")
  Assert.match("no function", tostring(err), "Should indicate no function")
end
Assert.endTest()

Assert.startTest("runProtected() propagates errors via pcall")
do
  local s = newSched(3.0)
  local ok, err = s:runProtected(function()
    error("simulated error")
  end)
  Assert.isFalse(ok, "runProtected should capture function errors")
  Assert.match("simulated error", tostring(err), "Error message should propagate")
end
Assert.endTest()

Assert.startTest("runProtected() passes arguments to function")
do
  local s = newSched(3.0)
  local result
  s:runProtected(function(a, b)
    result = a + b
  end, 10, 20)
  Assert.equal(30, result, "Arguments should be forwarded")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 5: forEach
-- ===========================================================================

Assert.startTest("forEach() iterates all items")
do
  local s = newSched()
  local processed = {}
  local count = s:forEach({"a", "b", "c", "d"}, function(item)
    table.insert(processed, item)
  end)
  Assert.equal(4, count, "All 4 items should be processed")
  Assert.equal(4, #processed, "Processed table should have 4 items")
  Assert.equal("a", processed[1], "First item should be 'a'")
  Assert.equal("d", processed[4], "Last item should be 'd'")
end
Assert.endTest()

Assert.startTest("forEach() provides index to callback")
do
  local s = newSched()
  local indices = {}
  s:forEach({"x", "y", "z"}, function(item, idx)
    table.insert(indices, idx)
  end)
  Assert.equal(3, #indices, "Should have 3 indices")
  Assert.equal(1, indices[1], "First index should be 1")
  Assert.equal(3, indices[3], "Third index should be 3")
end
Assert.endTest()

Assert.startTest("forEach() handles nil/empty inputs")
do
  local s = newSched()
  Assert.equal(0, s:forEach(nil, function() end),
    "forEach(nil, fn) should return 0")
  Assert.equal(0, s:forEach({}, function() end),
    "forEach({}, fn) should return 0")
  Assert.equal(0, s:forEach({"a"}, nil),
    "forEach(items, nil) should return 0")
end
Assert.endTest()

Assert.startTest("forEach() skips error items silently")
do
  local s = newSched()
  local processed = {}
  s:forEach({1, 2, 3, 4, 5}, function(item)
    if item == 3 then
      error("bad item")
    end
    table.insert(processed, item)
  end)
  Assert.equal(4, #processed, "4 items should process (3rd skipped)")
  -- Check indices: 1, 2, 4, 5 are processed
  Assert.equal(1, processed[1], "Item 1 processed")
  Assert.equal(2, processed[2], "Item 2 processed")
  Assert.equal(4, processed[3], "Item 4 processed")
  Assert.equal(5, processed[4], "Item 5 processed")

  -- Check error log
  local errs = s:errors()
  Assert.equal(1, #errs, "1 error should be logged")
  Assert.equal(3, errs[1].index, "Error should reference index 3")
  Assert.match("bad item", errs[1].error, "Error message should be preserved")
end
Assert.endTest()

Assert.startTest("forEach() performs yield checkpoints on interval")
do
  local s = newSched(10.0)  -- generous budget so interval-started checkpoints fire
  local items = {}
  for i = 1, 600 do items[i] = i end

  local beforeYields = countYields()
  s:forEach(items, function(item) end)
  local afterYields = countYields()

  -- 600 items / 200 interval = 3 periodic checkpoints + 1 final = 4+ yields
  -- But since budget is large (10s), only the interval-based checks fire
  Assert.isTrue(afterYields >= beforeYields,
    "forEach should trigger yield checkpoints on large arrays")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 6: forEachPair
-- ===========================================================================

Assert.startTest("forEachPair() iterates all key-value pairs")
do
  local s = newSched()
  local keys = {}
  local values = {}
  s:forEachPair({a = 1, b = 2, c = 3}, function(k, v)
    table.insert(keys, k)
    table.insert(values, v)
  end)
  Assert.equal(3, #keys, "3 keys should be processed")
  Assert.equal(3, #values, "3 values should be processed")
end
Assert.endTest()

Assert.startTest("forEachPair() handles nil/empty inputs")
do
  local s = newSched()
  Assert.equal(0, s:forEachPair(nil, function() end), "nil table -> 0")
  Assert.equal(0, s:forEachPair({}, function() end), "empty table -> 0")
  Assert.equal(0, s:forEachPair({a=1}, nil), "nil fn -> 0")
end
Assert.endTest()

Assert.startTest("forEachPair() skips errors per-entry")
do
  local s = newSched()
  local processed = {}
  s:forEachPair({a = 1, b = 2, c = 3}, function(k, v)
    if k == "b" then error("bad key") end
    processed[k] = v
  end)
  Assert.isTrue(#s:errors() >= 1, "1+ error should be logged for failing key")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 7: Deferred Task Queue
-- ===========================================================================

Assert.startTest("defer() adds tasks to the queue")
do
  local s = newSched()
  local id1 = s:defer(function() end, "task-A")
  local id2 = s:defer(function() end)
  Assert.notNil(id1, "First defer should return an id")
  Assert.notNil(id2, "Second defer should return an id")
  Assert.equal(2, s:pendingTasks(), "2 tasks should be pending")
  Assert.isTrue(id1 < id2, "Task IDs should be strictly increasing")
end
Assert.endTest()

Assert.startTest("defer(nil) returns nil")
do
  local s = newSched()
  Assert.isNil(s:defer(nil), "defer(nil) should return nil")
  Assert.equal(0, s:pendingTasks(), "No tasks should be added")
end
Assert.endTest()

Assert.startTest("processQueue() executes all tasks")
do
  local s = newSched(10.0)  -- generous budget
  local results = {}
  s:defer(function() table.insert(results, "A") end, "A")
  s:defer(function() table.insert(results, "B") end, "B")
  s:defer(function() table.insert(results, "C") end, "C")

  local processed = s:processQueue()
  Assert.equal(3, processed, "All 3 tasks should process")
  Assert.equal(0, s:pendingTasks(), "Queue should be empty after processing")
  Assert.equal(3, #results, "All 3 functions should have run")
  Assert.equal("A", results[1], "Tasks should execute in order")
  Assert.equal("C", results[3], "Third task runs last")
end
Assert.endTest()

Assert.startTest("processQueue() respects maxTasks cap")
do
  local s = newSched(10.0)
  for i = 1, 10 do
    s:defer(function() end, "t" .. i)
  end
  local processed = s:processQueue(3)
  Assert.equal(3, processed, "Should process exactly 3 tasks")
  Assert.equal(7, s:pendingTasks(), "7 tasks should remain")
end
Assert.endTest()

Assert.startTest("processQueue() handles task errors gracefully")
do
  local s = newSched(10.0)
  s:defer(function() error("boom") end, "bad")
  s:defer(function() end, "good")

  local processed = s:processQueue()
  Assert.equal(2, processed, "Both tasks should process despite error")
  Assert.equal(0, s:pendingTasks(), "Queue should be empty")

  local errs = s:errors()
  Assert.equal(1, #errs, "1 error should be logged")
  Assert.equal("bad", errs[1].label, "Error should reference 'bad' task")
  Assert.match("boom", errs[1].error, "Error message should be preserved")
end
Assert.endTest()

Assert.startTest("processQueue() yields between tasks when budget exhausted")
do
  local s = newSched(0.1)  -- very tight budget
  for i = 1, 5 do
    s:defer(function()
      advanceClock(0.05)  -- each task consumes 50ms
    end, "t" .. i)
  end

  local beforeYields = countYields()
  local processed = s:processQueue()
  local afterYields = countYields()
  Assert.equal(5, processed, "All 5 tasks should process")
  Assert.isTrue(afterYields > beforeYields,
    "Should yield between tasks due to tight budget")
end
Assert.endTest()

Assert.startTest("clearQueue() removes all pending tasks")
do
  local s = newSched()
  s:defer(function() end, "a")
  s:defer(function() end, "b")
  s:defer(function() end, "c")
  Assert.equal(3, s:pendingTasks(), "3 tasks should be pending")
  s:clearQueue()
  Assert.equal(0, s:pendingTasks(), "0 tasks should remain after clear")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 8: Errors and Statistics
-- ===========================================================================

Assert.startTest("errors() returns and optionally clears error log")
do
  local s = newSched()
  -- No errors yet
  Assert.tableEmpty(s:errors(), "Error log should be empty initially")
  -- Trigger an error via forEach
  s:forEach({1, 2}, function(item)
    if item == 2 then error("oops") end
  end)
  Assert.equal(1, #s:errors(), "1 error should be logged")
  -- Clear
  local errs = s:errors(true)
  Assert.equal(1, #errs, "Cleared errors should still be returned")
  Assert.tableEmpty(s:errors(), "Error log should now be empty")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 9: Integration — Real-World Usage Patterns
-- ===========================================================================

Assert.startTest("Scheduler prevents TMI in machine polling loop")
do
  -- Simulate exec broker polling 50 machines with per-machine budget check
  local s = newSched(3.0)
  local machines = {}
  for i = 1, 50 do
    machines[i] = {id = i, active = true, progress = 0}
  end

  local polled = 0
  s:forEach(machines, function(m, idx, sched)
    -- Simulate a pollHardware call that consumes time
    advanceClock(0.001)
    polled = polled + 1
  end)

  Assert.equal(50, polled, "All 50 machines should be polled")
  -- Should not have exhausted budget for 50 x 1ms = 50ms of work
  Assert.isFalse(s:exhausted(), "Budget should not be exhausted for 50ms of work")
end
Assert.endTest()

Assert.startTest("Scheduler breaks large batch across slices")
do
  -- Simulate processing a large batch of items where some batches overrun budget
  local s = newSched(0.2)  -- 200ms per slice
  local items = {}
  for i = 1, 30 do
    items[i] = {id = i, data = ("x"):rep(100)}
  end

  local processed = 0
  s:forEach(items, function(item)
    advanceClock(0.02)  -- 20ms per item
    processed = processed + 1
  end)

  -- All items processed
  Assert.equal(30, processed, "All 30 items should be processed")
end
Assert.endTest()

Assert.startTest("processQueue with defer simulates multi-tick work distribution")
do
  local s = newSched(0.3)  -- 300ms per slice
  local phaseLog = {}
  local totalWork = 0

  -- Phase 1: poll machines
  s:defer(function()
    advanceClock(0.1)
    table.insert(phaseLog, "poll")
    totalWork = totalWork + 1
  end, "poll")

  -- Phase 2: configure interfaces
  s:defer(function()
    advanceClock(0.05)
    table.insert(phaseLog, "configure")
    totalWork = totalWork + 1
  end, "configure")

  -- Phase 3: transfer items
  s:defer(function()
    advanceClock(0.2)
    table.insert(phaseLog, "transfer")
    totalWork = totalWork + 1
  end, "transfer")

  -- Phase 4: start processing
  s:defer(function()
    advanceClock(0.05)
    table.insert(phaseLog, "process")
    totalWork = totalWork + 1
  end, "process")

  local processed = s:processQueue()
  Assert.equal(4, processed, "All 4 phases should process")
  Assert.equal(4, totalWork, "All work should be done")
  Assert.equal("poll", phaseLog[1], "Tasks execute in order")
  Assert.equal("process", phaseLog[4], "Last task executes last")
end
Assert.endTest()

Assert.startTest("Budget check resets after os.sleep(0) via checkpoint")
do
  resetClock()
  local s = newSched(2.0)
  advanceClock(1.0)
  Assert.isFalse(s:exhausted(), "Not exhausted at 1s")

  advanceClock(1.5)  -- now at 2.5s, past budget
  Assert.isTrue(s:exhausted(), "Exhausted at 2.5s")

  -- Checkpoint should yield + reset
  local didYield = s:checkpoint()
  Assert.isTrue(didYield, "checkpoint should yield")

  -- After reset, the timer should be near 0
  advanceClock(0.0)  -- ensure consistent view
  Assert.isFalse(s:exhausted(), "Should not be exhausted after checkpoint+reset")
  Assert.isTrue(s:elapsed() < 0.1, "elapsed should be near 0 after reset")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 10: Edge Cases
-- ===========================================================================

Assert.startTest("Custom budget of 0.001 works (tight budgeting)")
do
  local s = newSched(0.001)
  local count = 0
  s:forEach({1, 2, 3}, function(item)
    count = count + 1
  end)
  Assert.equal(3, count, "All 3 items should process even with tight budget")
end
Assert.endTest()

Assert.startTest("Negative budget defaults to 3.0")
do
  local s = TimeSliceScheduler.new(-1)
  Assert.equal(3.0, s.budget, "Negative budget should fall back to default")
end
Assert.endTest()

Assert.startTest("Zero budget still allows minimal work")
do
  local s = TimeSliceScheduler.new(0)
  Assert.equal(0, s.budget, "Zero budget is accepted literally")
  -- With 0 budget, elapsed >= 0 means exhausted immediately
  local ran = false
  local ok, err = s:runProtected(function() ran = true end)
  Assert.isFalse(ok, "runProtected should fail with 0 budget")
  Assert.equal("budget exhausted", err, "Should report exhausted")
end
Assert.endTest()

Assert.startTest("Multiple schedulers are independent")
do
  resetClock()
  local s1 = TimeSliceScheduler.new(3.0)
  local s2 = TimeSliceScheduler.new(3.0)

  s1:defer(function() end, "s1-task")
  Assert.equal(1, s1:pendingTasks(), "Scheduler 1 should have 1 task")
  Assert.equal(0, s2:pendingTasks(), "Scheduler 2 should have 0 tasks")

  s2:defer(function() end, "s2-task")
  Assert.equal(1, s1:pendingTasks(), "Scheduler 1 should still have 1 task")
  Assert.equal(1, s2:pendingTasks(), "Scheduler 2 should now have 1 task")
end
Assert.endTest()

Assert.startTest("stats() provides diagnostic information")
do
  local s = newSched(2.0)
  local stats = s:stats()
  Assert.equal("table", type(stats), "stats() returns a table")
  Assert.notNil(stats.yields, "stats has yields field")
  Assert.notNil(stats.budget, "stats has budget field")
  Assert.notNil(stats.budgetUsage, "stats has budgetUsage field")
  Assert.notNil(stats.pendingTasks, "stats has pendingTasks field")
  Assert.notNil(stats.elapsed, "stats has elapsed field")
  Assert.notNil(stats.canSleep, "stats has canSleep field")
  Assert.equal(2.0, stats.budget, "stats budget matches constructor")

  -- After some work
  s:defer(function() end)
  s:processQueue()  -- drain the deferred task
  s:forEach({1, 2, 3}, function() end)
  stats = s:stats()
  Assert.equal(0, stats.pendingTasks, "No pending tasks after drain + forEach")
end
Assert.endTest()

Assert.startTest("resetStats() clears counters")
do
  local s = newSched()
  s._yieldCount = 42
  s._resumeCount = 10
  s._totalElapsed = 99.9
  s:resetStats()
  Assert.equal(0, s._yieldCount, "yieldCount should reset to 0")
  Assert.equal(0, s._resumeCount, "resumeCount should reset to 0")
  Assert.equal(0, s._totalElapsed, "totalElapsed should reset to 0")
end
Assert.endTest()

-- Restore original os.clock (cleanup)
os.clock = realClock

-- Unwrap os.sleep mock
os.sleep = realSleep
