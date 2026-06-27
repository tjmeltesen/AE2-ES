--[[
test_logger_integration.lua — Integration tests for D3: Global Logger
  Supervisor integration + severity routing (Task D3)

Tests:
  1. LogEntry + LogRingBuffer import and basic operation
  2. LogFilter: severity filtering, origin filtering, text search
  3. LogExporter: append, flush, rotation
  4. GlobalLogger: alert extraction from TelemetryPayload
  5. Severity routing: INFO stays local, ERROR triggers alert
  6. Maintenance flag snapshot on CRITICAL
  7. Multiple brokers logging concurrently
  8. Log viewer filter + search
--]]

-- Path resolution
local function _load(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  package.path = "./src/?.lua;./?.lua;" .. package.path
  return require(name)
end

local LogEntry      = _load("log_entry")
local LogRingBuffer = _load("log_ring_buffer")
local GlobalLoggerMod = _load("global_logger")
local GlobalLogger  = GlobalLoggerMod.GlobalLogger
local LogFilter     = GlobalLoggerMod.LogFilter
local LogExporter   = GlobalLoggerMod.LogExporter

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
  if actual ~= nil then
    testResults.passed = testResults.passed + 1
    return true
  end
  testResults.failed = testResults.failed + 1
  local err = string.format("FAIL [%s]: expected non-nil", msg)
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
  local err = string.format("FAIL [%s]: '%s' does not match '%s'", msg, tostring(actual), pattern)
  table.insert(testResults.errors, err)
  print("  " .. err)
  return false
end

local function assertArrayLength(expected, tbl, msg)
  if #tbl == expected then
    testResults.passed = testResults.passed + 1
    return true
  end
  testResults.failed = testResults.failed + 1
  local err = string.format("FAIL [%s]: expected array length %d, got %d", msg, expected, #tbl)
  table.insert(testResults.errors, err)
  print("  " .. err)
  return false
end

-- ============================================================================
-- Mock Supervisor for testing
-- ============================================================================
local function makeMockSupervisor()
  local log = {}
  local logIndex = 0
  return {
    _log = log,
    _logIndex = logIndex,
    _loggerAlertFlash = nil,
    _logMessage = function(self, level, message)
      logIndex = logIndex + 1
      local entry = {
        id = logIndex,
        timestamp = os.clock(),
        level = level,
        message = message,
      }
      table.insert(log, entry)
      if #log > 200 then
        table.remove(log, 1)
      end
    end,
    logMessage = function(self, level, message)
      self:_logMessage(level, message)
    end,
    getLog = function(self, count)
      if count and count < #log then
        local start = #log - count + 1
        local result = {}
        for i = start, #log do
          table.insert(result, log[i])
        end
        return result
      end
      return log
    end,
    registerConsumer = function(self, name, callback)
      self._lastConsumerName = name
      self._lastCallback = callback
    end,
  }
end

-- ============================================================================
-- Helper: make a TelemetryPayload-style table
-- ============================================================================
local function makePayload(brokerId, alerts, hardwareMatrix)
  return {
    brokerId = brokerId or "test-broker",
    timestamp = os.time(),
    schemaVersion = 1,
    queueLength = 5,
    hardwareMatrix = hardwareMatrix or {},
    alerts = alerts or {},
  }
end

local function makeAlert(severity, message, machineAddress)
  return {
    severity = severity or "INFO",
    message = message or "test alert",
    machineAddress = machineAddress or nil,
  }
end

local function makeMachine(address, status, jobId, progress)
  return {
    address = address or "gt-machine-01",
    status = status or "AVAILABLE",
    activeJobId = jobId,
    progress = progress,
    maintenanceFlags = (status == "FAULTED") and { faultCode = 1, isRepairable = true } or nil,
  }
end

-- ============================================================================
-- Group 1: LogEntry + LogRingBuffer (D1 core, verify import works)
-- ============================================================================
local function testCoreDataStructures()
  print("\n--- Group 1: Core Data Structures ---")

  -- 1a. LogEntry creation
  local e = LogEntry.new("broker1", "INFO", "test message")
  assertNotNil(e, "LogEntry created")
  assertEqual("broker1", e.originId, "originId")
  assertEqual("INFO", e.severity, "severity")
  assertEqual("test message", e.message, "message")

  -- 1b. LogRingBuffer basic operation
  local buf = LogRingBuffer.new(5)
  buf:append(e)
  assertEqual(1, buf:count(), "buffer count 1")
  local all = buf:getAll()
  assertArrayLength(1, all, "getAll length 1")
  assertEqual("test message", all[1].message, "entry preserved")
end

-- ============================================================================
-- Group 2: LogFilter
-- ============================================================================
local function testLogFilter()
  print("\n--- Group 2: LogFilter ---")

  local filter = LogFilter.new()
  local entries = {
    LogEntry.new("b1", "DEBUG", "debug msg"),
    LogEntry.new("b1", "INFO", "info msg"),
    LogEntry.new("b2", "WARN", "warn msg"),
    LogEntry.new("b1", "ERROR", "error msg"),
    LogEntry.new("b2", "CRITICAL", "critical msg"),
  }

  -- 2a. Filter by severity
  local filtered = filter:bySeverity(entries, {"ERROR", "CRITICAL"})
  assertArrayLength(2, filtered, "2 ERROR/CRITICAL entries")
  assertEqual("ERROR", filtered[1].severity, "first is ERROR")
  assertEqual("CRITICAL", filtered[2].severity, "second is CRITICAL")

  -- 2b. Filter by origin
  local b1entries = filter:byOrigin(entries, "b1")
  assertArrayLength(3, b1entries, "3 b1 entries")
  for _, e in ipairs(b1entries) do
    assertEqual("b1", e.originId, "all from b1")
  end

  -- 2c. Text search
  local searchRes = filter:byText(entries, "critical")
  assertArrayLength(1, searchRes, "1 match for 'critical'")
  assertEqual("CRITICAL", searchRes[1].severity, "matched CRITICAL entry")

  -- 2d. Combined filter
  local combined = filter:filter(entries, {
    severities = {"WARN", "ERROR"},
    origin = "b1",
  })
  assertArrayLength(1, combined, "1 match: ERROR from b1")
  assertEqual("ERROR", combined[1].severity, "matched ERROR")
  assertEqual("b1", combined[1].originId, "from b1")

  -- 2e. No filter (returns all)
  local all = filter:filter(entries, {})
  assertArrayLength(5, all, "no filter returns all")
end

-- ============================================================================
-- Group 3: LogExporter
-- ============================================================================
local function testLogExporter()
  print("\n--- Group 3: LogExporter ---")

  -- 3a. Append and flush
  local exporter = LogExporter.new({ logPath = os.tmpname() or "/tmp/test_logger.log" })
  exporter:append(LogEntry.new("b1", "INFO", "test"))
  exporter:append(LogEntry.new("b2", "WARN", "warning"))
  assertEqual(2, exporter:getBufferSize(), "2 buffered entries")
  exporter:flush()
  assertEqual(0, exporter:getBufferSize(), "0 after flush")

  -- 3b. checkRotation is safe on empty buffer
  exporter:checkRotation()
  assertEqual(0, exporter:getBufferSize(), "still 0 after rotation check")

  -- 3c. Format entry
  local formatted = exporter:_formatEntry({ timestamp = 1000, severity = "ERROR", originId = "b1", message = "fail" })
  assertMatch("1000", formatted, "contains timestamp")
  assertMatch("ERROR", formatted, "contains severity")
  assertMatch("b1", formatted, "contains origin")
  assertMatch("fail", formatted, "contains message")

  -- 3d. Get log path
  assertNotNil(exporter:getLogPath(), "log path set")
  -- Path may be a temp file; just verify it's non-empty
  assertTrue(#exporter:getLogPath() > 0, "log path non-empty")
end

-- ============================================================================
-- Group 4: GlobalLogger — construction and registration
-- ============================================================================
local function testGlobalLoggerConstruction()
  print("\n--- Group 4: GlobalLogger Construction ---")

  -- 4a. Create with defaults
  local logger = GlobalLogger.new()
  assertNotNil(logger, "GlobalLogger created")
  assertNotNil(logger:getLocalBuffer(), "has local buffer")
  assertNotNil(logger:getFilter(), "has filter")
  assertNotNil(logger:getExporter(), "has exporter")
  assertEqual(0, logger:getLocalBuffer():count(), "buffer starts empty")

  -- 4b. Registration with supervisor
  local sv = makeMockSupervisor()
  logger:register(sv)
  assertEqual("global_logger", sv._lastConsumerName, "registered as global_logger")
  assertNotNil(sv._lastCallback, "callback registered")
end

-- ============================================================================
-- Group 5: Severity Routing — INFO stays local, ERROR triggers alert
-- ============================================================================
local function testSeverityRouting()
  print("\n--- Group 5: Severity Routing ---")

  -- 5a. INFO alert stays local only
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    local payload = makePayload("broker-A", {
      makeAlert("INFO", "routine check"),
      makeAlert("INFO", "all clear"),
    })

    sv._lastCallback(payload, sv)

    local localEntries = logger:getLocalBuffer():getAll()
    assertArrayLength(2, localEntries, "2 INFO entries in local buffer")
    assertEqual("INFO", localEntries[1].severity, "first is INFO")
    assertEqual("INFO", localEntries[2].severity, "second is INFO")

    -- Should NOT be in supervisor log
    local svLog = sv:getLog()
    assertArrayLength(0, svLog, "no entries in supervisor log for INFO")

    -- No alert flash
    assertFalse(logger:hasAlertFlash(), "no alert flash for INFO")
    assertNil(sv._loggerAlertFlash, "no supervisor flash for INFO")
  end

  -- 5b. WARN alert goes to supervisor too
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    local payload = makePayload("broker-B", {
      makeAlert("WARNING", "disk space low"),
    })

    sv._lastCallback(payload, sv)

    local localEntries = logger:getLocalBuffer():getAll()
    assertArrayLength(1, localEntries, "1 WARN entry in local buffer")
    assertEqual("WARN", localEntries[1].severity, "WARN mapped correctly")

    local svLog = sv:getLog()
    assertArrayLength(1, svLog, "1 entry in supervisor log")
    assertMatch("WARN", svLog[1].level, "supervisor log level is WARN")
    -- Check message contains broker ID (using plain string.find since '-' is a Lua pattern char)
    assertTrue(string.find(svLog[1].message, "broker-B", 1, true) ~= nil, "supervisor log contains broker ID")

    -- No alert flash for WARN
    assertFalse(logger:hasAlertFlash(), "no alert flash for WARN")
  end

  -- 5c. ERROR alert triggers flash
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    local payload = makePayload("broker-C", {
      makeAlert("ERROR", "transfer failed"),
    })

    sv._lastCallback(payload, sv)

    local localEntries = logger:getLocalBuffer():getAll()
    assertArrayLength(1, localEntries, "1 ERROR entry in local buffer")
    assertEqual("ERROR", localEntries[1].severity, "ERROR mapped correctly")

    local svLog = sv:getLog()
    assertArrayLength(1, svLog, "1 entry in supervisor log")
    assertMatch("ERROR", svLog[1].level, "supervisor log level is ERROR")

    -- Alert flash set
    assertTrue(logger:hasAlertFlash(), "alert flash set for ERROR")
    assertTrue(sv._loggerAlertFlash, "supervisor flash set")
  end

  -- 5d. CRITICAL alert triggers flash and maintenance snapshot
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    local hwMatrix = {
      makeMachine("gt-01", "FAULTED"),
      makeMachine("gt-02", "AVAILABLE"),
      makeMachine("gt-03", "FAULTED"),
    }

    local payload = makePayload("broker-D", {
      makeAlert("CRITICAL", "Meltdown imminent"),
    }, hwMatrix)

    sv._lastCallback(payload, sv)

    local localEntries = logger:getLocalBuffer():getAll()
    assertArrayLength(1, localEntries, "1 CRITICAL entry in local buffer")

    local svLog = sv:getLog()
    assertArrayLength(1, svLog, "1 entry in supervisor log")
    assertMatch("CRITICAL", svLog[1].level, "supervisor log level is CRITICAL")

    -- Alert flash set
    assertTrue(logger:hasAlertFlash(), "alert flash set for CRITICAL")

    -- Maintenance snapshot captured
    local snapshots = logger:getMaintenanceSnapshots()
    assertArrayLength(1, snapshots, "1 maintenance snapshot")
    assertEqual("broker-D", snapshots[1].brokerId, "snapshot brokerId")
    assertEqual(2, snapshots[1].faultedCount, "2 faulted machines captured")
  end
end

-- ============================================================================
-- Group 6: Maintenance flag snapshot on CRITICAL
-- ============================================================================
local function testMaintenanceSnapshot()
  print("\n--- Group 6: Maintenance Snapshot ---")

  -- 6a. CRITICAL with no faulted machines (snapshot still created, zero count)
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    local payload = makePayload("broker-E", {
      makeAlert("CRITICAL", "core issue"),
    }, { makeMachine("gt-01", "AVAILABLE"), makeMachine("gt-02", "PROCESSING") })

    sv._lastCallback(payload, sv)

    local snapshots = logger:getMaintenanceSnapshots()
    assertArrayLength(1, snapshots, "1 snapshot (zero faulted machines)")
    assertEqual(0, snapshots[1].faultedCount, "0 faulted machines")
  end

  -- 6b. CRITICAL captures specific machine details
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    local hwMatrix = {
      makeMachine("gt-fault-01", "FAULTED", "job-123", nil),
      makeMachine("gt-fault-02", "FAULTED", "job-456", 50),
    }

    local payload = makePayload("broker-F", {
      makeAlert("CRITICAL", "machine error"),
    }, hwMatrix)

    sv._lastCallback(payload, sv)

    local snapshots = logger:getMaintenanceSnapshots()
    assertArrayLength(1, snapshots, "1 snapshot")
    assertEqual(2, snapshots[1].faultedCount, "2 faulted machines")
    local machines = snapshots[1].faultedMachines
    assertArrayLength(2, machines, "2 faulted machine details")
    assertEqual("gt-fault-01", machines[1].address, "first machine address")
    assertEqual("gt-fault-02", machines[2].address, "second machine address")
    assertEqual("job-123", machines[1].activeJobId, "active job captured")
    assertEqual("job-456", machines[2].activeJobId, "second job captured")
  end

  -- 6c. Only last 50 snapshots kept
  do
    local sv = makeMockSupervisor()
    local logger = GlobalLogger.new()
    logger:register(sv)

    for i = 1, 60 do
      local payload = makePayload("broker-" .. i, {
        makeAlert("CRITICAL", "snapshot " .. i),
      })
      sv._lastCallback(payload, sv)
    end

    local snapshots = logger:getMaintenanceSnapshots()
    assertArrayLength(50, snapshots, "capped at 50 snapshots")
    assertEqual("broker-60", snapshots[50].brokerId, "newest snapshot preserved")
  end
end

-- ============================================================================
-- Group 7: Multiple brokers logging concurrently
-- ============================================================================
local function testMultipleBrokers()
  print("\n--- Group 7: Multiple Brokers ---")

  local sv = makeMockSupervisor()
  local logger = GlobalLogger.new({ localBufferSize = 100 })
  logger:register(sv)

  -- Simulate 3 brokers sending payloads with various severity alerts
  local brokers = { "broker-alpha", "broker-beta", "broker-gamma" }
  local severities = { "INFO", "WARNING", "ERROR" }

  for _, brokerId in ipairs(brokers) do
    for _, sev in ipairs(severities) do
      local payload = makePayload(brokerId, {
        makeAlert(sev, brokerId .. " " .. sev .. " alert"),
      })
      sv._lastCallback(payload, sv)
    end
  end

  -- 7a. All 9 entries (3 brokers x 3 severities) in local buffer
  local localCount = logger:getLocalBuffer():count()
  assertEqual(9, localCount, "9 entries total in local buffer")

  -- 7b. All entries accessible via getEntries
  local allEntries = logger:getEntries()
  assertArrayLength(9, allEntries, "getEntries returns all 9")

  -- 7c. Filter by origin
  local alphaEntries = logger:getEntries({ origin = "broker-alpha" })
  assertArrayLength(3, alphaEntries, "3 entries from broker-alpha")

  -- 7d. Filter by severity
  local errorEntries = logger:getEntries({ severities = {"ERROR"} })
  assertArrayLength(3, errorEntries, "3 ERROR entries (one per broker)")
  for _, e in ipairs(errorEntries) do
    assertEqual("ERROR", e.severity, "all are ERROR")
  end

  -- 7e. Supervisor log has WARN and ERROR entries (not INFO)
  local svLog = sv:getLog()
  assertEqual(6, #svLog, "6 entries in supervisor log (3 WARN + 3 ERROR)")
end

-- ============================================================================
-- Group 8: LogExporter buffer and flush integration
-- ============================================================================
local function testExporterIntegration()
  print("\n--- Group 8: Exporter Integration ---")

  local sv = makeMockSupervisor()
  local logger = GlobalLogger.new()
  logger:register(sv)

  -- Send several payloads
  for i = 1, 5 do
    local payload = makePayload("broker", {
      makeAlert("WARNING", "warning " .. i),
      makeAlert("ERROR", "error " .. i),
    })
    sv._lastCallback(payload, sv)
  end

  -- Exporter buffer should be empty (auto-flushed after each payload)
  assertEqual(0, logger:getExporter():getBufferSize(), "exporter buffer empty after auto-flush")

  -- Stats show correct counts
  local stats = logger:getStats()
  assertEqual(5, stats.totalProcessed, "5 payloads processed")
  assertEqual(10, stats.totalEntries, "10 entries created (2 per payload)")
  assertEqual(5, stats.alertsBySeverity.WARN, "5 WARN entries")
  assertEqual(5, stats.alertsBySeverity.ERROR, "5 ERROR entries")
end

-- ============================================================================
-- Group 9: Log viewer filter + search
-- ============================================================================
local function testLogViewerFilters()
  print("\n--- Group 9: Log Viewer Filters ---")

  local sv = makeMockSupervisor()
  local logger = GlobalLogger.new()
  logger:register(sv)

  -- Send payloads from different brokers with different severities
  local payloads = {
    makePayload("b1", { makeAlert("INFO", "b1 info") }),
    makePayload("b1", { makeAlert("ERROR", "b1 error") }),
    makePayload("b2", { makeAlert("WARNING", "b2 warning") }),
    makePayload("b2", { makeAlert("CRITICAL", "b2 critical") }),
    makePayload("b1", { makeAlert("DEBUG", "b1 debug") }),
    makePayload("b3", { makeAlert("INFO", "b3 info") }),
  }

  for _, p in ipairs(payloads) do
    sv._lastCallback(p, sv)
  end

  -- 9a. Filter by severity
  local criticals = logger:getEntries({ severities = {"CRITICAL"} })
  assertArrayLength(1, criticals, "1 CRITICAL entry")
  assertEqual("b2", criticals[1].originId, "from broker b2")

  -- 9b. Filter by origin
  local b1entries = logger:getEntries({ origin = "b1" })
  assertArrayLength(3, b1entries, "3 entries from b1")

  -- 9c. Combined filter
  local b1Errors = logger:getEntries({ severities = {"ERROR"}, origin = "b1" })
  assertArrayLength(1, b1Errors, "1 ERROR from b1")

  -- 9d. Text search
  local criticalMsgs = logger:getEntries({ search = "critical" })
  assertArrayLength(1, criticalMsgs, "1 entry matching 'critical'")
  assertEqual("b2 critical", criticalMsgs[1].message, "matched message text")

  -- 9e. Text search case-insensitive
  local warningMsgs = logger:getEntries({ search = "WARNING" })
  assertArrayLength(1, warningMsgs, "1 entry matching 'WARNING' (case-insensitive)")

  -- 9f. Limit results
  local limited = logger:getEntries({ limit = 2 })
  assertArrayLength(2, limited, "limited to 2 entries")

  -- 9g. No matches
  local noMatch = logger:getEntries({ search = "nonexistent" })
  assertArrayLength(0, noMatch, "no matches for nonexistent search")
end

-- ============================================================================
-- Group 10: Clear alert flash
-- ============================================================================
local function testClearAlertFlash()
  print("\n--- Group 10: Clear Alert Flash ---")

  local sv = makeMockSupervisor()
  local logger = GlobalLogger.new()
  logger:register(sv)

  local payload = makePayload("broker", { makeAlert("ERROR", "something broke") })
  sv._lastCallback(payload, sv)

  assertTrue(logger:hasAlertFlash(), "flash set")

  logger:clearAlertFlash()
  assertFalse(logger:hasAlertFlash(), "flash cleared")

  -- Multiple errors only need one clear
  local payload2 = makePayload("broker", {
    makeAlert("ERROR", "error 1"),
    makeAlert("ERROR", "error 2"),
    makeAlert("CRITICAL", "critical!"),
  })
  sv._lastCallback(payload2, sv)
  assertTrue(logger:hasAlertFlash(), "flash set again after new errors")
end

-- ============================================================================
-- Run all tests
-- ============================================================================
local function runAll()
  print("=== Global Logger Integration Test Suite (D3) ===")
  print()

  testCoreDataStructures()
  testLogFilter()
  testLogExporter()
  testGlobalLoggerConstruction()
  testSeverityRouting()
  testMaintenanceSnapshot()
  testMultipleBrokers()
  testExporterIntegration()
  testLogViewerFilters()
  testClearAlertFlash()

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

-- Standalone execution
if arg and arg[0] and (arg[0]:match("test_logger_integration%.lua$") or arg[0]:match("test_logger_integration")) then
  local success = runAll()
  os.exit(success and 0 or 1)
end

return runAll
