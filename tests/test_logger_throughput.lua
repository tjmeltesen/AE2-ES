-- test_logger_throughput.lua
-- D4: Global Logger — Throughput verification tests
--
-- Validates LogRingBuffer under rapid-fire injection of 100 log entries
-- within a single tick, confirming:
--   1. maxSize memory boundary unchanged after injection
--   2. No data frames dropped — count matches injected
--   3. Head/tail pointers correct before and after overflow
--   4. getLatest(100) returns exactly 100 newest entries
--   5. Buffer under-fill: fewer entries than maxSize
--   6. Exact-fill: exactly maxSize entries
--   7. Overflow: 2x maxSize entries (oldest overwritten, newest 100 preserved)

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

local LogRingBuffer = require("lib.log_ring_buffer")
local LogEntry = require("lib.log_entry")

-- ===========================================================================
-- Helpers
-- ===========================================================================

--- Create a lightweight log entry for throughput injection.
-- Uses a simple table shape matching LogEntry expectations.
-- @param id number  unique index for the entry
-- @param severity string  severity level
-- @return table
local function makeEntry(id, severity, jobId)
  return {
    timestamp = os.epoch(),
    originId  = "broker-" .. ((id % 4) + 1),
    severity  = severity or "INFO",
    message   = "log entry #" .. tostring(id),
    jobId     = jobId or nil,
  }
end

-- ===========================================================================
-- Test Group 1: Basic Buffer Operations
-- ===========================================================================

-- Test 1.1: Empty buffer returns nothing
Assert.startTest("Empty buffer: count 0, getLatest returns empty")
do
  local buf = LogRingBuffer.new(100)
  Assert.equal(0, buf:count(), "Empty buffer count is 0")
  Assert.equal(100, buf:maxSize(), "maxSize preserved")
  local latest = buf:getLatest(10)
  Assert.type("table", latest, "getLatest returns table")
  Assert.equal(0, #latest, "getLatest on empty buffer returns empty")
  local all = buf:getAll()
  Assert.equal(0, #all, "getAll on empty buffer returns empty")
end
Assert.endTest()

-- Test 1.2: Single entry append and retrieve
Assert.startTest("Single entry: append and retrieve")
do
  local buf = LogRingBuffer.new(100)
  local entry = makeEntry(1, "INFO", "job-1")
  buf:append(entry)
  Assert.equal(1, buf:count(), "Count is 1 after single append")

  local latest = buf:getLatest(1)
  Assert.equal(1, #latest, "getLatest(1) returns 1 entry")
  Assert.equal(entry.message, latest[1].message, "Retrieved entry matches")
  Assert.equal(entry.originId, latest[1].originId, "originId preserved")
end
Assert.endTest()

-- Test 1.3: Buffer under-fill — fewer entries than maxSize
Assert.startTest("Buffer under-fill: 50 entries in 100-size buffer")
do
  local buf = LogRingBuffer.new(100)
  for i = 1, 50 do
    buf:append(makeEntry(i, "INFO"))
  end
  Assert.equal(50, buf:count(), "Count is 50")
  Assert.equal(100, buf:maxSize(), "maxSize unchanged at 100")

  local all = buf:getAll()
  Assert.equal(50, #all, "getAll returns 50 entries")
  -- Verify chronological order: first entry should be #1
  Assert.isTrue(all[1].message:find("#1"), "First entry is entry #1")
  Assert.isTrue(all[50].message:find("#50"), "Last entry is entry #50")
end
Assert.endTest()

-- Test 1.4: Exact fill — exactly 100 entries in 100-size buffer
Assert.startTest("Exact fill: 100 entries in 100-size buffer")
do
  local buf = LogRingBuffer.new(100)
  for i = 1, 100 do
    buf:append(makeEntry(i, "INFO"))
  end
  Assert.equal(100, buf:count(), "Count is 100 (exact fill)")
  Assert.equal(100, buf:maxSize(), "maxSize unchanged at 100")

  local all = buf:getAll()
  Assert.equal(100, #all, "getAll returns 100 entries")
  Assert.isTrue(all[1].message:find("#1"), "Oldest entry is #1")
  Assert.isTrue(all[100].message:find("#100"), "Newest entry is #100")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 2: Throughput — 100 Rapid Entries (Within Single Tick)
-- ===========================================================================

-- Test 2.1: Inject 100 entries rapidly, verify count
Assert.startTest("100 rapid entries: count == 100")
do
  local buf = LogRingBuffer.new(150)
  for i = 1, 100 do
    buf:append(makeEntry(i, "DEBUG"))
    -- No yield/sleep — simulating single-tick injection
  end
  Assert.equal(100, buf:count(), "100 entries stored")
  Assert.equal(150, buf:maxSize(), "maxSize unchanged")
end
Assert.endTest()

-- Test 2.2: No data frames dropped during rapid injection
Assert.startTest("100 rapid entries: no data frames dropped")
do
  local buf = LogRingBuffer.new(100)
  local injected = {}
  for i = 1, 100 do
    local entry = makeEntry(i, "INFO", "throughput-" .. i)
    injected[i] = entry
    buf:append(entry)
  end

  -- Verify every entry is retrievable via getAll
  local all = buf:getAll()
  Assert.equal(100, #all, "getAll returns 100 entries")

  -- Verify messages match in order
  local missing = 0
  for i = 1, 100 do
    if not all[i] or all[i].message ~= injected[i].message then
      missing = missing + 1
    end
  end
  Assert.equal(0, missing, "All 100 entries match: zero dropped or corrupted")
end
Assert.endTest()

-- Test 2.3: getLatest(100) returns exactly 100 newest entries
Assert.startTest("getLatest(100): returns newest 100 entries chronologically")
do
  local buf = LogRingBuffer.new(150)
  for i = 1, 140 do
    buf:append(makeEntry(i, "WARN"))
  end

  local latest = buf:getLatest(100)
  Assert.equal(100, #latest, "getLatest(100) returns 100 entries")
  Assert.isTrue(latest[1].message:find("#41"), "Oldest in latest is #41 (140-100+1)")
  Assert.isTrue(latest[100].message:find("#140"), "Newest in latest is #140")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 3: Overflow Behavior (Entries > maxSize)
-- ===========================================================================

-- Test 3.1: Overflow — head/tail pointers correct after wrap
Assert.startTest("Overflow wrap: head/tail pointers correct after 2x entries")
do
  local buf = LogRingBuffer.new(50)

  -- Inject 100 entries into 50-size buffer
  for i = 1, 100 do
    buf:append(makeEntry(i, "ERROR", "overflow-" .. i))
  end

  -- maxSize unchanged
  Assert.equal(50, buf:maxSize(), "maxSize unchanged at 50")
  -- Count capped at maxSize
  Assert.equal(50, buf:count(), "Count capped at 50 after overflow")

  -- getAll returns 50 entries (the newest 50)
  local all = buf:getAll()
  Assert.equal(50, #all, "getAll returns 50 entries after overflow")
  -- Oldest entry should be #51 (first non-overwritten)
  Assert.isTrue(all[1].message:find("#51"), "Oldest is entry #51")
  -- Newest entry should be #100
  Assert.isTrue(all[50].message:find("#100"), "Newest is entry #100")
end
Assert.endTest()

-- Test 3.2: Overwrite oldest entries — verify newest N preserved
Assert.startTest("Overflow: oldest overwritten, newest 50 preserved exactly")
do
  local buf = LogRingBuffer.new(50)

  -- Inject 200 entries
  for i = 1, 200 do
    buf:append(makeEntry(i, "INFO"))
  end

  Assert.equal(50, buf:count(), "Count is 50")
  local all = buf:getAll()
  Assert.equal(50, #all, "getAll returns 50")

  -- Verify the newest 50 (entries 151-200) are preserved
  for i, entry in ipairs(all) do
    local expectedNum = 150 + i
    Assert.isTrue(entry.message:find("#" .. expectedNum),
      string.format("Position %d is entry #%d", i, expectedNum))
  end
end
Assert.endTest()

-- Test 3.3: getLatest beyond count returns all available
Assert.startTest("getLatest with N > count returns min(count, N) entries")
do
  local buf = LogRingBuffer.new(100)
  for i = 1, 30 do
    buf:append(makeEntry(i, "TRACE"))
  end

  local latest = buf:getLatest(100)
  Assert.equal(30, #latest, "getLatest(100) on 30-entry buffer returns 30")
  Assert.isTrue(latest[1].message:find("#1"), "First is entry #1")
  Assert.isTrue(latest[30].message:find("#30"), "Last is entry #30")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 4: Memory and Boundary Verification
-- ===========================================================================

-- Test 4.1: maxSize memory boundary — create, fill, overflow, measure
Assert.startTest("Memory boundary: maxSize=100 stays at 100 through overflow")
do
  local maxSize = 100
  local buf = LogRingBuffer.new(maxSize)

  -- Baseline: maxSize
  Assert.equal(maxSize, buf:maxSize(), "Initial maxSize correct")

  -- Fill to exact capacity
  for i = 1, maxSize do
    buf:append(makeEntry(i, "TEST"))
  end
  Assert.equal(maxSize, buf:maxSize(), "maxSize unchanged after exact fill")
  Assert.equal(maxSize, buf:count(), "Count equals maxSize at exact fill")

  -- Overflow: inject 3x capacity
  for i = 1, 300 do
    buf:append(makeEntry(maxSize + i, "TEST"))
  end
  Assert.equal(maxSize, buf:maxSize(), "maxSize unchanged after 3x overflow")
  Assert.equal(maxSize, buf:count(), "Count capped at maxSize after 3x overflow")
end
Assert.endTest()

-- Test 4.2: Head pointer wraps correctly through multiple cycles
Assert.startTest("Head pointer: correct after multiple full wraps")
do
  local buf = LogRingBuffer.new(10)

  -- First fill (entries 1-10)
  for i = 1, 10 do
    buf:append(makeEntry(i, "CYCLE1"))
  end
  Assert.equal(10, buf:count())

  -- Second fill — overwrites first 5 (entries 11-15), then wraps (16-20)
  for i = 1, 10 do
    buf:append(makeEntry(10 + i, "CYCLE2"))
  end
  Assert.equal(10, buf:count())

  -- Third fill — overwrites remaining from CYCLE1 and all of CYCLE2
  for i = 1, 10 do
    buf:append(makeEntry(20 + i, "CYCLE3"))
  end
  Assert.equal(10, buf:count())

  -- Should have entries 21-30 (the most recent 10)
  local all = buf:getAll()
  Assert.equal(10, #all)
  Assert.isTrue(all[1].message:find("#21"), "Oldest is #21 after 3 cycles")
  Assert.isTrue(all[10].message:find("#30"), "Newest is #30 after 3 cycles")
end
Assert.endTest()

-- Test 4.3: getLatest consistency after overflow
Assert.startTest("getLatest: consistent and complete after overflow")
do
  local buf = LogRingBuffer.new(50)

  for i = 1, 80 do
    buf:append(makeEntry(i, "DEBUG"))
  end

  -- getLatest(30) should return entries 51-80
  local latest30 = buf:getLatest(30)
  Assert.equal(30, #latest30, "getLatest(30) returns 30")
  Assert.isTrue(latest30[1].message:find("#51"), "First in latest30 is #51")
  Assert.isTrue(latest30[30].message:find("#80"), "Last in latest30 is #80")

  -- getLatest(50) should return entries 31-80
  local latest50 = buf:getLatest(50)
  Assert.equal(50, #latest50, "getLatest(50) returns 50")
  Assert.isTrue(latest50[1].message:find("#31"), "First in latest50 is #31")
  Assert.isTrue(latest50[50].message:find("#80"), "Last in latest50 is #80")

  -- Verify both getLatest calls return consistent data
  -- latest30 should be the tail end of latest50
  for i = 1, 30 do
    Assert.equal(latest50[20 + i].message, latest30[i].message,
      string.format("getLatest consistency: offset %d matches", i))
  end
end
Assert.endTest()

-- ===========================================================================
-- Test Group 5: Edge Cases
-- ===========================================================================

-- Test 5.1: Buffer of size 1
Assert.startTest("Edge case: buffer size 1")
do
  local buf = LogRingBuffer.new(1)

  buf:append(makeEntry(1, "INFO"))
  Assert.equal(1, buf:count(), "Count is 1")
  Assert.equal(1, buf:maxSize(), "maxSize is 1")

  buf:append(makeEntry(2, "WARN"))
  Assert.equal(1, buf:count(), "Count still 1 after overflow")
  Assert.equal(1, buf:maxSize(), "maxSize unchanged")

  local all = buf:getAll()
  Assert.equal(1, #all)
  Assert.isTrue(all[1].message:find("#2"), "Only entry #2 remains after overwrite")

  local latest = buf:getLatest(1)
  Assert.isTrue(latest[1].message:find("#2"), "getLatest returns entry #2")
end
Assert.endTest()

-- Test 5.2: Buffer clear and reuse
Assert.startTest("Clear and reuse: buffer resets to empty")
do
  local buf = LogRingBuffer.new(100)
  for i = 1, 50 do
    buf:append(makeEntry(i, "INFO"))
  end
  Assert.equal(50, buf:count())

  buf:clear()
  Assert.equal(0, buf:count(), "Count is 0 after clear")
  Assert.equal(100, buf:maxSize(), "maxSize preserved after clear")

  local latest = buf:getLatest(10)
  Assert.equal(0, #latest, "getLatest returns empty after clear")

  -- Reuse buffer
  for i = 1, 25 do
    buf:append(makeEntry(i, "POST_CLEAR"))
  end
  Assert.equal(25, buf:count(), "Reusable after clear: count 25")
  local all = buf:getAll()
  Assert.isTrue(all[1].message:find("#1"), "First reused entry is #1")
  Assert.isTrue(all[25].message:find("#25"), "Last reused entry is #25")
end
Assert.endTest()

-- Test 5.3: getLatest with zero count returns empty
Assert.startTest("getLatest(0) returns empty array")
do
  local buf = LogRingBuffer.new(100)
  for i = 1, 10 do
    buf:append(makeEntry(i, "INFO"))
  end
  local result = buf:getLatest(0)
  Assert.type("table", result, "getLatest(0) returns table")
  Assert.equal(0, #result, "getLatest(0) returns empty array")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 6: Single-Tick Stress Injection
-- ===========================================================================

-- Test 6.1: Inject exactly maxSize entries in tight loop
Assert.startTest("Single-tick stress: inject 100 entries with maxSize=100")
do
  local buf = LogRingBuffer.new(100)
  for i = 1, 100 do
    buf:append(makeEntry(i, "STRESS"))
  end
  Assert.equal(100, buf:count(), "All 100 entries stored")
  Assert.equal(100, buf:maxSize(), "maxSize boundary intact")

  local all = buf:getAll()
  Assert.equal(100, #all)
  -- Verify sequential integrity: no gaps, no reordering
  for i = 1, 100 do
    Assert.isTrue(all[i].message:find("#" .. i),
      string.format("Entry %d sequential", i))
  end
end
Assert.endTest()

-- Test 6.2: Inject 100 entries into 30-size buffer, verify newest 30
Assert.startTest("Single-tick stress: 100 entries into maxSize=30, newest 30 preserved")
do
  local buf = LogRingBuffer.new(30)
  for i = 1, 100 do
    buf:append(makeEntry(i, "STRESS"))
  end
  Assert.equal(30, buf:count(), "Count capped at 30")
  Assert.equal(30, buf:maxSize(), "maxSize unchanged")

  local all = buf:getAll()
  Assert.equal(30, #all)
  -- Newest 30: entries 71-100
  for i = 1, 30 do
    local expectedNum = 70 + i
    Assert.isTrue(all[i].message:find("#" .. expectedNum),
      string.format("Position %d is entry #%d", i, expectedNum))
  end

  -- getLatest(30) == getAll
  local latest = buf:getLatest(30)
  Assert.equal(30, #latest)
  for i = 1, 30 do
    Assert.equal(all[i].message, latest[i].message,
      string.format("getLatest matches getAll at position %d", i))
  end
end
Assert.endTest()

-- Test 6.3: Inject with LogEntry.new (full object creation)
Assert.startTest("Single-tick with LogEntry.new: 100 created and injected")
do
  local buf = LogRingBuffer.new(100)
  local created = 0

  for i = 1, 100 do
    local ok, entry = pcall(LogEntry.new,
      "broker-" .. (i % 4 + 1),
      (i % 5 == 0) and "ERROR" or "INFO",
      "throughput message #" .. i,
      (i % 3 == 0) and ("job-" .. i) or nil
    )
    if ok then
      buf:append(entry)
      created = created + 1
    end
  end

  Assert.equal(100, created, "100 LogEntry objects created")
  Assert.equal(100, buf:count(), "100 entries stored")

  -- Verify all entries have proper LogEntry shape
  local all = buf:getAll()
  for i, entry in ipairs(all) do
    Assert.notNil(entry.timestamp, "Entry " .. i .. " has timestamp")
    Assert.notNil(entry.originId, "Entry " .. i .. " has originId")
    Assert.notNil(entry.severity, "Entry " .. i .. " has severity")
    Assert.notNil(entry.message, "Entry " .. i .. " has message")
    Assert.isTrue(entry.severity == "INFO" or entry.severity == "ERROR",
      "Entry " .. i .. " severity is valid")
  end
end
Assert.endTest()
