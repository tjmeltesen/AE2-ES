--[[
test_logger_core.lua — Unit tests for LogEntry + LogRingBuffer (D1)
AE2 Execution System (AE2-ES)

Tests: LogEntry creation (all 5 severity levels), invalid severity rejection,
       LogEntry serialization, ring buffer append/overwrite, getLatest,
       empty buffer edge cases, 100-entry throughput test.
]]--

-- Path resolution — works when loaded from run_tests.lua (which sets ./src/?.lua
-- on package.path) AND when run standalone from project root.
local function _load(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  -- Running standalone — add src/ to module path
  package.path = "./src/?.lua;./?.lua;" .. package.path
  return require(name)
end

local LogEntry     = _load("log_entry")
local LogRingBuffer = _load("log_ring_buffer")

-- ============================================================================
-- Test framework
-- ============================================================================
local testResults = { passed = 0, failed = 0, errors = {} }

local function assertEqual(expected, actual, msg)
  msg = msg or ""
  if expected == actual then
    testResults.passed = testResults.passed + 1
    return true
  end
  testResults.failed = testResults.failed + 1
  local err = string.format("FAIL [%s]: expected %s, got %s", msg, tostring(expected), tostring(actual))
  table.insert(testResults.errors, err)
  print("  " .. err)
  return false
end

local function assertTrue(actual, msg)
  return assertEqual(true, actual, msg)
end

local function assertFalse(actual, msg)
  return assertEqual(false, actual, msg)
end

local function assertNil(actual, msg)
  msg = msg or ""
  if actual == nil then
    testResults.passed = testResults.passed + 1
    return true
  end
  testResults.failed = testResults.failed + 1
  local err = string.format("FAIL [%s]: expected nil, got %s", msg, tostring(actual))
  table.insert(testResults.errors, err)
  print("  " .. err)
  return false
end

local function assertNotNil(actual, msg)
  msg = msg or ""
  if actual ~= nil then
    testResults.passed = testResults.passed + 1
    return true
  end
  testResults.failed = testResults.failed + 1
  local err = string.format("FAIL [%s]: expected non-nil, got nil", msg)
  table.insert(testResults.errors, err)
  print("  " .. err)
  return false
end

local function assertMatch(pattern, actual, msg)
  msg = msg or ""
  if type(actual) == "string" and string.find(actual, pattern) then
    testResults.passed = testResults.passed + 1
    return true
  end
  testResults.failed = testResults.failed + 1
  local err = string.format("FAIL [%s]: '%s' does not match pattern '%s'", msg, tostring(actual), pattern)
  table.insert(testResults.errors, err)
  print("  " .. err)
  return false
end

local function assertThrows(fn, msg)
  msg = msg or ""
  local ok, err = pcall(fn)
  if ok then
    testResults.failed = testResults.failed + 1
    local errMsg = string.format("FAIL [%s]: expected error but function succeeded", msg)
    table.insert(testResults.errors, errMsg)
    print("  " .. errMsg)
    return false
  end
  testResults.passed = testResults.passed + 1
  return true
end

local function assertTableEmpty(tbl, msg)
  msg = msg or ""
  if type(tbl) ~= "table" then
    testResults.failed = testResults.failed + 1
    local err = string.format("FAIL [%s]: expected table, got %s", msg, type(tbl))
    table.insert(testResults.errors, err)
    print("  " .. err)
    return false
  end
  if next(tbl) ~= nil then
    testResults.failed = testResults.failed + 1
    local err = string.format("FAIL [%s]: expected empty table, got %d entries", msg, #tbl)
    table.insert(testResults.errors, err)
    print("  " .. err)
    return false
  end
  testResults.passed = testResults.passed + 1
  return true
end

local function assertArrayLength(expected, tbl, msg)
  msg = msg or ""
  if #tbl ~= expected then
    testResults.failed = testResults.failed + 1
    local err = string.format("FAIL [%s]: expected array length %d, got %d", msg, expected, #tbl)
    table.insert(testResults.errors, err)
    print("  " .. err)
    return false
  end
  testResults.passed = testResults.passed + 1
  return true
end

-- ============================================================================
-- Group 1: LogEntry — Constructor
-- ============================================================================
local function testLogEntryCreation()
  print("\n--- Group 1: LogEntry Creation ---")

  -- 1a. DEBUG level
  do
    local e = LogEntry.new("test", "DEBUG", "debug message")
    assertNotNil(e, "entry not nil")
    assertNotNil(e.timestamp, "timestamp set")
    assertEqual("test", e.originId, "originId")
    assertEqual("DEBUG", e.severity, "severity DEBUG")
    assertEqual("debug message", e.message, "message")
    assertNil(e.jobId, "jobId nil when omitted")
  end

  -- 1b. INFO level
  do
    local e = LogEntry.new("broker1", "INFO", "info message")
    assertEqual("INFO", e.severity, "severity INFO")
  end

  -- 1c. WARN level
  do
    local e = LogEntry.new("broker1", "WARN", "warning")
    assertEqual("WARN", e.severity, "severity WARN")
  end

  -- 1d. ERROR level
  do
    local e = LogEntry.new("broker1", "ERROR", "error occurred")
    assertEqual("ERROR", e.severity, "severity ERROR")
  end

  -- 1e. CRITICAL level
  do
    local e = LogEntry.new("supervisor", "CRITICAL", "critical failure")
    assertEqual("CRITICAL", e.severity, "severity CRITICAL")
  end

  -- 1f. With jobId
  do
    local e = LogEntry.new("broker1", "INFO", "job started", "job-001")
    assertNotNil(e.jobId, "jobId set")
    assertEqual("job-001", e.jobId, "jobId value")
  end

  -- 1g. Empty jobId string normalised to nil
  do
    local e = LogEntry.new("broker1", "INFO", "no job", "")
    assertNil(e.jobId, "empty string normalised to nil")
  end

  -- 1h. Timestamp is a number
  do
    local e = LogEntry.new("test", "DEBUG", "timing")
    assertEqual("number", type(e.timestamp), "timestamp type")
    assertTrue(e.timestamp > 0, "timestamp positive")
  end
end

-- ============================================================================
-- Group 2: LogEntry — Invalid severity rejection
-- ============================================================================
local function testInvalidSeverity()
  print("\n--- Group 2: Invalid Severity ---")

  -- 2a. Completely invalid
  assertThrows(function()
    LogEntry.new("test", "INVALID_SEV", "should fail")
  end, "rejects invalid severity string")

  -- 2b. Mispelled
  assertThrows(function()
    LogEntry.new("test", "WARNN", "mispelled")
  end, "rejects mispelled severity")

  -- 2c. Lowercase (case-sensitive)
  assertThrows(function()
    LogEntry.new("test", "debug", "lowercase not valid")
  end, "rejects lowercase severity")

  -- 2d. Nil severity
  assertThrows(function()
    LogEntry.new("test", nil, "nil severity")
  end, "rejects nil severity")
end

-- ============================================================================
-- Group 3: LogEntry — Serialization
-- ============================================================================
local function testLogEntrySerialization()
  print("\n--- Group 3: LogEntry Serialization ---")

  -- 3a. toTelemetryPayload structure
  do
    local e = LogEntry.new("broker1", "ERROR", "something broke", "job-042")
    local payload = e:toTelemetryPayload()
    assertNotNil(payload, "payload not nil")
    assertEqual("table", type(payload), "payload is table")
    assertEqual("log_entry", payload.type, "type field")
    assertEqual(e.timestamp, payload.timestamp, "timestamp matches")
    assertEqual("broker1", payload.originId, "originId")
    assertEqual("ERROR", payload.severity, "severity")
    assertEqual("something broke", payload.message, "message")
    assertEqual("job-042", payload.jobId, "jobId")
  end

  -- 3b. Serialization without jobId
  do
    local e = LogEntry.new("supervisor", "INFO", "all good")
    local payload = e:toTelemetryPayload()
    assertEqual("all good", payload.message, "message without jobId")
    assertNil(payload.jobId, "jobId nil in payload")
  end

  -- 3c. Payload is flat (no nested tables)
  do
    local e = LogEntry.new("test", "DEBUG", "flat check")
    local payload = e:toTelemetryPayload()
    for k, v in pairs(payload) do
      assertNotNil(v, "value for key " .. tostring(k) .. " not nil")
    end
  end
end

-- ============================================================================
-- Group 4: LogRingBuffer — Basic append & count
-- ============================================================================
local function testRingBufferBasic()
  print("\n--- Group 4: Ring Buffer Basic ---")

  -- 4a. New buffer empty
  do
    local buf = LogRingBuffer.new()
    assertEqual(0, buf:count(), "new buffer count 0")
    assertEqual(500, buf:maxSize(), "default maxSize 500")
  end

  -- 4b. Custom maxSize
  do
    local buf = LogRingBuffer.new(10)
    assertEqual(10, buf:maxSize(), "custom maxSize 10")
  end

  -- 4c. Single append
  do
    local buf = LogRingBuffer.new(10)
    local e = LogEntry.new("test", "INFO", "first entry")
    buf:append(e)
    assertEqual(1, buf:count(), "count 1 after one append")
  end

  -- 4d. Multiple appends
  do
    local buf = LogRingBuffer.new(10)
    for i = 1, 5 do
      buf:append(LogEntry.new("test", "INFO", "entry " .. i))
    end
    assertEqual(5, buf:count(), "count 5 after 5 appends")
  end
end

-- ============================================================================
-- Group 5: LogRingBuffer — Append beyond maxSize (overwrite)
-- ============================================================================
local function testRingBufferOverwrite()
  print("\n--- Group 5: Ring Buffer Overwrite ---")

  -- 5a. Fill buffer exactly, then overwrite oldest
  do
    local buf = LogRingBuffer.new(3)
    buf:append(LogEntry.new("t", "DEBUG", "a"))
    buf:append(LogEntry.new("t", "DEBUG", "b"))
    buf:append(LogEntry.new("t", "DEBUG", "c"))
    assertEqual(3, buf:count(), "count 3 at capacity")

    -- Overwrite oldest (a) with d
    buf:append(LogEntry.new("t", "DEBUG", "d"))
    assertEqual(3, buf:count(), "count still 3 after overwrite")

    local all = buf:getAll()
    assertArrayLength(3, all, "3 entries after overwrite")

    -- Should be b, c, d (a was overwritten)
    local msgs = {}
    for _, entry in ipairs(all) do
      table.insert(msgs, entry.message)
    end
    assertEqual("b", msgs[1], "first entry is 'b' (oldest) after overwrite")
    assertEqual("c", msgs[2], "second entry is 'c'")
    assertEqual("d", msgs[3], "third entry is 'd' (newest)")
  end

  -- 5b. Multiple overwrite cycles
  do
    local buf = LogRingBuffer.new(2)
    buf:append(LogEntry.new("t", "INFO", "e1"))
    buf:append(LogEntry.new("t", "INFO", "e2"))
    buf:append(LogEntry.new("t", "INFO", "e3")) -- overwrites e1
    buf:append(LogEntry.new("t", "INFO", "e4")) -- overwrites e2

    local all = buf:getAll()
    assertArrayLength(2, all, "2 entries after 4 appends to size-2 buffer")
    assertEqual("e3", all[1].message, "oldest is e3")
    assertEqual("e4", all[2].message, "newest is e4")
  end

  -- 5c. Many overwrites (buffer of 10, push 25)
  do
    local buf = LogRingBuffer.new(10)
    for i = 1, 25 do
      buf:append(LogEntry.new("t", "DEBUG", "msg-" .. i))
    end
    assertEqual(10, buf:count(), "count capped at 10")

    local all = buf:getAll()
    assertArrayLength(10, all, "10 entries after 25 pushes")
    -- Should be msg-16 through msg-25
    assertEqual("msg-16", all[1].message, "oldest after overwrap = msg-16")
    assertEqual("msg-25", all[10].message, "newest = msg-25")
  end
end

-- ============================================================================
-- Group 6: LogRingBuffer — getLatest
-- ============================================================================
local function testRingBufferGetLatest()
  print("\n--- Group 6: Ring Buffer getLatest ---")

  -- 6a. Get latest from partially-filled buffer
  do
    local buf = LogRingBuffer.new(10)
    buf:append(LogEntry.new("t", "INFO", "msg-1"))
    buf:append(LogEntry.new("t", "INFO", "msg-2"))
    buf:append(LogEntry.new("t", "INFO", "msg-3"))

    local latest = buf:getLatest(2)
    assertArrayLength(2, latest, "getLatest(2) returns 2 entries")
    assertEqual("msg-2", latest[1].message, "getLatest[1] = msg-2")
    assertEqual("msg-3", latest[2].message, "getLatest[2] = msg-3")
  end

  -- 6b. Get latest of 1 (newest only)
  do
    local buf = LogRingBuffer.new(10)
    buf:append(LogEntry.new("t", "INFO", "old"))
    buf:append(LogEntry.new("t", "INFO", "newest"))

    local latest = buf:getLatest(1)
    assertArrayLength(1, latest, "getLatest(1) = 1 entry")
    assertEqual("newest", latest[1].message, "getLatest(1) = newest")
  end

  -- 6c. Get latest more than available (returns all)
  do
    local buf = LogRingBuffer.new(10)
    buf:append(LogEntry.new("t", "INFO", "only"))

    local latest = buf:getLatest(999)
    assertArrayLength(1, latest, "getLatest(999) when 1 entry = 1")
    assertEqual("only", latest[1].message, "returns the one entry")
  end

  -- 6d. Get latest from full buffer after overwrap
  do
    local buf = LogRingBuffer.new(3)
    buf:append(LogEntry.new("t", "DEBUG", "a"))
    buf:append(LogEntry.new("t", "DEBUG", "b"))
    buf:append(LogEntry.new("t", "DEBUG", "c"))
    buf:append(LogEntry.new("t", "DEBUG", "d")) -- overwrites a

    local latest = buf:getLatest(2)
    assertArrayLength(2, latest, "getLatest(2) after overwrap")
    assertEqual("c", latest[1].message, "oldest in window = c")
    assertEqual("d", latest[2].message, "newest in window = d")
  end

  -- 6e. getLatest(0) returns empty
  do
    local buf = LogRingBuffer.new(5)
    buf:append(LogEntry.new("t", "INFO", "msg"))
    local latest = buf:getLatest(0)
    assertTableEmpty(latest, "getLatest(0) = empty table")
  end
end

-- ============================================================================
-- Group 7: LogRingBuffer — Empty buffer edge cases
-- ============================================================================
local function testRingBufferEmpty()
  print("\n--- Group 7: Empty Buffer Edge Cases ---")

  -- 7a. Empty buffer getAll
  do
    local buf = LogRingBuffer.new()
    assertTableEmpty(buf:getAll(), "getAll on empty buffer")
  end

  -- 7b. Empty buffer getLatest
  do
    local buf = LogRingBuffer.new()
    assertTableEmpty(buf:getLatest(5), "getLatest(5) on empty buffer")
    assertTableEmpty(buf:getLatest(1), "getLatest(1) on empty buffer")
    assertTableEmpty(buf:getLatest(0), "getLatest(0) on empty buffer")
  end

  -- 7c. Empty buffer count
  do
    local buf = LogRingBuffer.new(100)
    assertEqual(0, buf:count(), "empty buffer count 0")
  end

  -- 7d. Clear resets count
  do
    local buf = LogRingBuffer.new(5)
    buf:append(LogEntry.new("t", "INFO", "x"))
    buf:append(LogEntry.new("t", "INFO", "y"))
    assertEqual(2, buf:count(), "count 2 before clear")
    buf:clear()
    assertEqual(0, buf:count(), "count 0 after clear")
    assertTableEmpty(buf:getAll(), "getAll empty after clear")
  end

  -- 7e. Double clear is safe
  do
    local buf = LogRingBuffer.new(5)
    buf:clear()
    buf:clear()
    assertEqual(0, buf:count(), "count 0 after double clear")
  end
end

-- ============================================================================
-- Group 8: LogRingBuffer — 100-entry throughput test
-- ============================================================================
local function testRingBufferThroughput()
  print("\n--- Group 8: 100-Entry Throughput ---")

  -- 8a. 100 rapid injections within a single tick simulation
  do
    local buf = LogRingBuffer.new(100)
    for i = 1, 100 do
      buf:append(LogEntry.new("broker1", "DEBUG", "rapid-" .. i))
    end
    assertEqual(100, buf:count(), "100 entries stored")

    -- Verify all messages present in order
    local all = buf:getAll()
    assertArrayLength(100, all, "getAll returns 100 entries")

    for i = 1, 100 do
      assertEqual("rapid-" .. i, all[i].message, "message " .. i .. " preserved")
    end
  end

  -- 8b. 100 rapid injections into smaller buffer (verify overwrite order)
  do
    local buf = LogRingBuffer.new(50)
    for i = 1, 100 do
      buf:append(LogEntry.new("test", "INFO", "fast-" .. i))
    end
    assertEqual(50, buf:count(), "100 injections into size-50 buffer = 50")

    local all = buf:getAll()
    assertArrayLength(50, all, "50 entries retained")
    assertEqual("fast-51", all[1].message, "oldest = fast-51")
    assertEqual("fast-100", all[50].message, "newest = fast-100")
  end

  -- 8c. 100 injections, no overwrites (buffer larger than count)
  do
    local buf = LogRingBuffer.new(200)
    for i = 1, 100 do
      buf:append(LogEntry.new("test", "INFO", "slow-" .. i))
    end
    assertEqual(100, buf:count(), "100 entries in size-200 buffer")

    local all = buf:getAll()
    assertArrayLength(100, all, "100 entries from getAll")
    assertEqual("slow-1", all[1].message, "oldest = slow-1")
    assertEqual("slow-100", all[100].message, "newest = slow-100")
  end
end

-- ============================================================================
-- Run all tests
-- ============================================================================
local function runAll()
  print("=== LogEntry + LogRingBuffer Test Suite (D1) ===")
  print()

  testLogEntryCreation()
  testInvalidSeverity()
  testLogEntrySerialization()
  testRingBufferBasic()
  testRingBufferOverwrite()
  testRingBufferGetLatest()
  testRingBufferEmpty()
  testRingBufferThroughput()

  print()
  print("========================================")
  print("  Results: " .. testResults.passed .. " passed, " .. testResults.failed .. " failed")

  if testResults.failed > 0 then
    print()
    print("  FAILURES:")
    for _, err in ipairs(testResults.errors) do
      print("    " .. err)
    end
  end

  print("========================================")
  print()

  return testResults.failed == 0
end

-- When running standalone (not loaded by run_tests.lua), exit with code
if arg and arg[0] and (arg[0]:match("test_logger_core%.lua$")) then
  local success = runAll()
  os.exit(success and 0 or 1)
end

return runAll
