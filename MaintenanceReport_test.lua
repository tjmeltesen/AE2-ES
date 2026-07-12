--[[
MaintenanceReport_test.lua — Unit test suite for A6: MaintenanceReport
AE2 Execution System (AE2-ES)

Tests cover:
  1.  Constructor — defaults and custom machineId
  2.  toHumanReadable — all 9 fault codes (0–8)
  3.  toHumanReadable — severity formatting (INFO vs WARNING/CRITICAL)
  4.  toHumanReadable — unknown code fallback
  5.  getSeverity — returns correct severity per code
  6.  getGuidance — returns guidance string per code
  7.  isFaultRepairable — repairable codes return true
  8.  isFaultRepairable — non-repairable codes (0, 8, unknown) return false
  9.  logToHistory — appends entry and returns index
  10. logToHistory — auto-trim at max capacity
  11. logToHistory — stores derived fields (severity, report, isRepairable)
  12. reportFault — updates faultCode and isRepairable
  13. reportFault — logs entry to history
  14. clearFault — clears when fault active
  15. clearFault — no-op when no fault
  16. getHistory — returns all entries with no limit
  17. getHistory — with limit returns most recent N only
  18. getLastReport — nil when empty, entry after log
  19. toTelemetry — returns flat table with correct keys/values
  20. toString — multi-line report with all sections
  21. reset — clears all state
  22. Consecutive faults — history accumulates correctly
]]--

-- Minimal test runner
local function runTests()
  local passed = 0
  local failed = 0
  local errors = {}

  local function assertEqual(expected, actual, label)
    if expected == actual then
      passed = passed + 1
      return true
    end
    failed = failed + 1
    table.insert(errors, string.format("FAIL [%s]: expected %s, got %s",
      label, tostring(expected), tostring(actual)))
    return false
  end

  local function assertTrue(actual, label)
    return assertEqual(true, actual, label)
  end

  local function assertFalse(actual, label)
    return assertEqual(false, actual, label)
  end

  local function assertMatch(pattern, actual, label)
    if type(actual) == "string" and string.find(actual, pattern) then
      passed = passed + 1
      return true
    end
    failed = failed + 1
    table.insert(errors, string.format("FAIL [%s]: string '%s' does not match '%s'",
      label, tostring(actual), pattern))
    return false
  end

  print("=== MaintenanceReport Test Suite ===")
  print()

  -- ==========================================================================
  -- Group 1: Constructor
  -- ==========================================================================
  print("--- Group 1: Constructor ---")

  do
    local mr = MaintenanceReport.new("gt_machine_01")
    assertEqual("gt_machine_01", mr.machineId, "machineId is set from argument")
    assertEqual(0, mr.faultCode, "faultCode defaults to 0")
    assertFalse(mr.isRepairable, "isRepairable defaults to false")
  end

  do
    local mr = MaintenanceReport.new()
    assertEqual("unknown", mr.machineId, "machineId defaults to 'unknown'")
  end

  -- ==========================================================================
  -- Group 2: toHumanReadable — all 9 fault codes
  -- ==========================================================================
  print("--- Group 2: toHumanReadable — all fault codes ---")

  do
    local cases = {
      {code = 0, expect = "No Fault"},
      {code = 1, expect = "Power Starvation"},
      {code = 2, expect = "Item Jam"},
      {code = 3, expect = "Fluid Issue"},
      {code = 4, expect = "Ghost Items"},
      {code = 5, expect = "No Recipe"},
      {code = 6, expect = "Overflow"},
      {code = 7, expect = "Disconnected"},
      {code = 8, expect = "Proxy Error"},
      {code = 9, expect = "Needs Maintenance"},
      {code = 10, expect = "Has Problems"},
      {code = 11, expect = "Incomplete Structure"},
    }
    local mr = MaintenanceReport.new("test")
    for _, c in ipairs(cases) do
      local result = mr:toHumanReadable(c.code)
      assertMatch(c.expect, result, "code " .. c.code .. " contains '" .. c.expect .. "'")
    end
  end

  -- ==========================================================================
  -- Group 3: Severity formatting
  -- ==========================================================================
  print("--- Group 3: Severity formatting ---")

  do
    local mr = MaintenanceReport.new("test")
    -- Code 0 (INFO) should NOT have brackets
    local msg0 = mr:toHumanReadable(0)
    assertEqual("No Fault — machine operating normally", msg0, "code 0 has no severity bracket")
    -- Code 1 (CRITICAL) should have [CRITICAL]
    local msg1 = mr:toHumanReadable(1)
    assertMatch("%[CRITICAL%]", msg1, "code 1 has [CRITICAL] prefix")
    -- Code 2 (WARNING) should have [WARNING]
    local msg2 = mr:toHumanReadable(2)
    assertMatch("%[WARNING%]", msg2, "code 2 has [WARNING] prefix")
  end

  -- ==========================================================================
  -- Group 4: Unknown code fallback
  -- ==========================================================================
  print("--- Group 4: Unknown code fallback ---")

  do
    local mr = MaintenanceReport.new("test")
    local msg99 = mr:toHumanReadable(99)
    assertMatch("Unknown Fault", msg99, "unknown code 99 returns fallback")
    local msg999 = mr:toHumanReadable(999)
    assertMatch("Unknown Fault", msg999, "unknown code 999 returns fallback")
  end

  -- ==========================================================================
  -- Group 5: getSeverity
  -- ==========================================================================
  print("--- Group 5: getSeverity ---")

  do
    local mr = MaintenanceReport.new("test")
    assertEqual(MaintenanceReport.SEVERITY.INFO, mr:getSeverity(0), "code 0 severity is INFO")
    assertEqual(MaintenanceReport.SEVERITY.CRITICAL, mr:getSeverity(1), "code 1 severity is CRITICAL")
    assertEqual(MaintenanceReport.SEVERITY.WARNING, mr:getSeverity(2), "code 2 severity is WARNING")
    assertEqual(MaintenanceReport.SEVERITY.WARNING, mr:getSeverity(5), "code 5 severity is WARNING")
    assertEqual(MaintenanceReport.SEVERITY.CRITICAL, mr:getSeverity(7), "code 7 severity is CRITICAL")
  end

  -- ==========================================================================
  -- Group 6: getGuidance
  -- ==========================================================================
  print("--- Group 6: getGuidance ---")

  do
    local mr = MaintenanceReport.new("test")
    local g0 = mr:getGuidance(0)
    assertMatch("No action needed", g0, "code 0 guidance mentions no action")
    local g1 = mr:getGuidance(1)
    assertMatch("EU supply", g1, "code 1 guidance mentions EU supply")
    local g8 = mr:getGuidance(8)
    assertMatch("Restart OC", g8, "code 8 guidance mentions restart OC")
    local g99 = mr:getGuidance(99)
    assertMatch("Manual inspection", g99, "unknown code guidance mentions manual inspection")
  end

  -- ==========================================================================
  -- Group 7: isFaultRepairable — repairable codes
  -- ==========================================================================
  print("--- Group 7: isFaultRepairable — repairable ---")

  do
    local mr = MaintenanceReport.new("test")
    assertTrue(mr:isFaultRepairable(1), "code 1 (power) is repairable")
    assertTrue(mr:isFaultRepairable(2), "code 2 (jam) is repairable")
    assertTrue(mr:isFaultRepairable(3), "code 3 (fluid) is repairable")
    assertTrue(mr:isFaultRepairable(4), "code 4 (ghost) is repairable")
    assertTrue(mr:isFaultRepairable(5), "code 5 (recipe) is repairable")
    assertTrue(mr:isFaultRepairable(6), "code 6 (overflow) is repairable")
    assertTrue(mr:isFaultRepairable(7), "code 7 (disconnect) is repairable")
  end

  -- ==========================================================================
  -- Group 8: isFaultRepairable — non-repairable
  -- ==========================================================================
  print("--- Group 8: isFaultRepairable — non-repairable ---")

  do
    local mr = MaintenanceReport.new("test")
    assertFalse(mr:isFaultRepairable(0), "code 0 (none) is not repairable")
    assertFalse(mr:isFaultRepairable(8), "code 8 (proxy) is not repairable")
    assertFalse(mr:isFaultRepairable(99), "unknown code is not repairable")
    assertFalse(mr:isFaultRepairable(-1), "negative code is not repairable")
  end

  -- ==========================================================================
  -- Group 9: logToHistory — basic append
  -- ==========================================================================
  print("--- Group 9: logToHistory — basic append ---")

  do
    local mr = MaintenanceReport.new("test")
    local idx = mr:logToHistory({code = 2, description = "Items stuck in output bus"})
    assertEqual(1, idx, "first log entry returns index 1")
    assertEqual(1, #mr._history, "history has 1 entry")
    assertEqual(2, mr._history[1].code, "entry stores fault code")
    assertEqual("Items stuck in output bus", mr._history[1].description, "entry stores description")
    local idx2 = mr:logToHistory({code = 7})
    assertEqual(2, idx2, "second log entry returns index 2")
    assertEqual(2, #mr._history, "history has 2 entries")
  end

  -- ==========================================================================
  -- Group 10: logToHistory — auto-trim at max capacity
  -- ==========================================================================
  print("--- Group 10: logToHistory — auto-trim ---")

  do
    local mr = MaintenanceReport.new("trim_test")
    -- Override max history to 5 for this test
    mr._maxHistory = 5
    for i = 1, 7 do
      mr:logToHistory({code = 1, description = "Event #" .. i})
    end
    assertEqual(5, #mr._history, "history trimmed to 5 entries")
    -- The oldest 2 should have been removed
    assertMatch("#3", mr._history[1].description, "first entry is event #3 (oldest 2 dropped)")
    assertMatch("#7", mr._history[5].description, "last entry is event #7")
  end

  -- ==========================================================================
  -- Group 11: logToHistory — derived fields
  -- ==========================================================================
  print("--- Group 11: logToHistory — derived fields ---")



  do
    local mr = MaintenanceReport.new("test")
    mr:logToHistory({code = 1, description = "No power"})
    assertEqual("CRITICAL", mr._history[1].severity, "entry severity for code 1 is CRITICAL")
    assertTrue(mr._history[1].isRepairable, "entry isRepairable for code 1 is true")
    assertMatch("Power Starvation", mr._history[1].report, "entry has report text")
  end

  -- ==========================================================================
  -- Group 12: reportFault — updates fields
  -- ==========================================================================
  print("--- Group 12: reportFault ---")

  do
    local mr = MaintenanceReport.new("machine_a")
    mr:reportFault(2, "Items blocking output bus")
    assertEqual(2, mr.faultCode, "reportFault sets faultCode to 2")
    assertTrue(mr.isRepairable, "reportFault sets isRepairable for code 2")
  end

  do
    local mr = MaintenanceReport.new("machine_a")
    mr:reportFault(8, "Proxy failed")
    assertEqual(8, mr.faultCode, "reportFault sets faultCode to 8")
    assertFalse(mr.isRepairable, "reportFault sets isRepairable false for code 8")
  end

  -- ==========================================================================
  -- Group 13: reportFault — logs to history
  -- ==========================================================================
  print("--- Group 13: reportFault — history ---")

  do
    local mr = MaintenanceReport.new("test")
    mr:reportFault(3, "Fluid tank full")
    assertEqual(1, #mr._history, "history has 1 entry after reportFault")
    assertEqual(3, mr._history[1].code, "history entry stores the fault code")
  end

  -- ==========================================================================
  -- Group 14: clearFault — clears when active
  -- ==========================================================================
  print("--- Group 14: clearFault ---")

  do
    local mr = MaintenanceReport.new("test")
    mr:reportFault(4, "Ghost items detected")
    assertTrue(mr.faultCode ~= 0, "fault is active before clear")

    local cleared = mr:clearFault("Flushed interface")
    assertTrue(cleared, "clearFault returns true")
    assertEqual(0, mr.faultCode, "faultCode reset to 0")
    assertFalse(mr.isRepairable, "isRepairable reset to false")
  end

  -- ==========================================================================
  -- Group 15: clearFault — no-op when no fault
  -- ==========================================================================
  print("--- Group 15: clearFault — no-op when no fault ---")

  do
    local mr = MaintenanceReport.new("test")
    assertEqual(0, mr.faultCode, "initially no fault")
    local cleared = mr:clearFault("Nothing to clear")
    assertFalse(cleared, "clearFault returns false when no fault active")
  end

  -- ==========================================================================
  -- Group 16: getHistory — returns all
  -- ==========================================================================
  print("--- Group 16: getHistory — all entries ---")

  do
    local mr = MaintenanceReport.new("test")
    for i = 1, 3 do
      mr:logToHistory({code = i, description = "Event " .. i})
    end
    local all = mr:getHistory()
    assertEqual(3, #all, "getHistory returns all 3 entries")
    assertEqual(1, all[1].code, "entry 1 has code 1")
    assertEqual(3, all[3].code, "entry 3 has code 3")
  end

  -- ==========================================================================
  -- Group 17: getHistory — with limit
  -- ==========================================================================
  print("--- Group 17: getHistory — with limit ---")

  do
    local mr = MaintenanceReport.new("test")
    for i = 1, 10 do
      mr:logToHistory({code = i})
    end
    local recent = mr:getHistory(3)
    assertEqual(3, #recent, "getHistory(3) returns 3 entries")
    assertEqual(8, recent[1].code, "first entry is code 8 (oldest of the 3 newest)")
    assertEqual(10, recent[3].code, "last entry is code 10 (newest)")
  end

  -- ==========================================================================
  -- Group 18: getLastReport
  -- ==========================================================================
  print("--- Group 18: getLastReport ---")

  do
    local mr = MaintenanceReport.new("test")
    assertEqual(nil, mr:getLastReport(), "getLastReport is nil before any log")
    mr:logToHistory({code = 5})
    assertEqual(5, mr:getLastReport().code, "last report has code 5")
    mr:logToHistory({code = 7})
    assertEqual(7, mr:getLastReport().code, "last report updates to code 7")
  end

  -- ==========================================================================
  -- Group 19: toTelemetry
  -- ==========================================================================
  print("--- Group 19: toTelemetry ---")

  do
    local mr = MaintenanceReport.new("machine_b")
    mr:reportFault(1, "EU starvation")
    local t = mr:toTelemetry()
    assertEqual("machine_b", t.machineId, "telemetry includes machineId")
    assertEqual(1, t.faultCode, "telemetry includes faultCode")
    assertTrue(t.isRepairable, "telemetry includes isRepairable")
    assertMatch("Power Starvation", t.faultSummary, "telemetry includes faultSummary")
    assertTrue(t.lastReportAt > 0, "telemetry includes lastReportAt timestamp")
    assertEqual(1, t.historyCount, "telemetry includes historyCount")
  end

  do
    local mr = MaintenanceReport.new("clean")
    local t = mr:toTelemetry()
    assertEqual(0, t.lastReportAt, "telemetry lastReportAt is 0 when no history")
    assertEqual(0, t.historyCount, "telemetry historyCount is 0")
  end

  -- ==========================================================================
  -- Group 20: toString
  -- ==========================================================================
  print("--- Group 20: toString ---")

  do
    local mr = MaintenanceReport.new("machine_c")
    local s = mr:toString()
    assertMatch("=== Maintenance Report ===", s, "toString has header")
    assertMatch("Machine: machine_c", s, "toString has machine ID")
    assertMatch("No Fault", s, "toString shows no-fault status")
  end

  do
    local mr = MaintenanceReport.new("machine_d")
    mr:reportFault(2, "Jam detected")
    local s = mr:toString()
    assertMatch("=== Maintenance Report ===", s, "faulty toString has header")
    assertMatch("Machine: machine_d", s, "faulty toString has machine ID")
    assertMatch("Item Jam", s, "faulty toString mentions Item Jam")
    assertMatch("Repairable: true", s, "faulty toString shows repairable status")
    assertMatch("Check output bus", s, "faulty toString includes guidance")
    assertMatch("History", s, "faulty toString includes history section")
  end

  -- ==========================================================================
  -- Group 21: reset
  -- ==========================================================================
  print("--- Group 21: reset ---")

  do
    local mr = MaintenanceReport.new("test")
    mr:reportFault(6, "Buffer overflow")
    mr:logToHistory({code = 1})
    assertEqual(6, mr.faultCode, "fault is set before reset")
    assertEqual(2, #mr._history, "history has entries before reset")

    mr:reset()
    assertEqual(0, mr.faultCode, "faultCode is 0 after reset")
    assertFalse(mr.isRepairable, "isRepairable is false after reset")
    assertEqual(0, #mr._history, "history is empty after reset")
    assertEqual(nil, mr._lastReport, "lastReport is nil after reset")
  end

  -- ==========================================================================
  -- Group 22: Consecutive faults — history accumulates
  -- ==========================================================================
  print("--- Group 22: Consecutive faults ---")

  do
    local mr = MaintenanceReport.new("test")
    mr:reportFault(1, "Power issue")
    mr:reportFault(2, "Now a jam")
    mr:reportFault(7, "Now disconnected")
    assertEqual(7, mr.faultCode, "latest fault code is 7")
    assertEqual(3, #mr._history, "history has 3 entries")
    assertEqual(1, mr._history[1].code, "first entry is code 1")
    assertEqual(7, mr._history[3].code, "last entry is code 7")

    -- Clear and verify resolution logged
    mr:clearFault("Reconnected adapter")
    assertEqual(0, mr.faultCode, "fault cleared")
    assertEqual(4, #mr._history, "clear adds 4th history entry")
    assertEqual(0, mr._history[4].code, "clear entry has code 0")
  end

  -- ==========================================================================
  -- Summary
  -- ==========================================================================
  print()
  print(string.format("=== Results: %d passed, %d failed ===", passed, failed))
  if #errors > 0 then
    print("Failures:")
    for _, e in ipairs(errors) do
      print("  " .. e)
    end
  end

  return passed, failed, errors
end

-- Run: load module explicitly (not from arg[1] which may be '-e' in embedded runs)
MaintenanceReport = dofile("MaintenanceReport.lua") or MaintenanceReport
_G.MaintenanceReport = MaintenanceReport  -- ensure available globally

local p, f, errs = runTests()
if f > 0 then
  os.exit(1)
end
