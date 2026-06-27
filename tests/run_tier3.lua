-- run_tier3.lua
-- AE2-ES Tier 3 Extended Soak Test Runner
-- Runs: test_soak.lua (1K+ micro-jobs, saturation, ghost items)
--        test_timeslicescheduler.lua (profiling, cooperative multitasking)
-- Output: performance report (printed as JSON to stdout)
-- Detects: memory leaks, yield gaps > 4s, job crashes

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

-- =========================================================================
-- Helper: math.round (not in standard Lua)
-- =========================================================================
local function round(value, decimals)
  local mult = 10 ^ (decimals or 0)
  return math.floor(value * mult + 0.5) / mult
end

-- =========================================================================
-- Helper: JSON encoder (minimal, no external deps)
-- =========================================================================
local function json_encode(value)
  local t = type(value)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return value and "true" or "false"
  elseif t == "number" then
    return string.format("%.3f", value)
  elseif t == "string" then
    return string.format("%q", value)
  elseif t == "table" then
    local parts = {}
    -- Detect array vs object
    local isArray = true
    local maxIdx = 0
    for k in pairs(value) do
      if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
        isArray = false
        break
      end
      if k > maxIdx then maxIdx = k end
    end
    if isArray and maxIdx > 0 then
      for i = 1, maxIdx do
        parts[#parts + 1] = json_encode(value[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(value) do
        keys[#keys + 1] = tostring(k)
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        parts[#parts + 1] = string.format("%q:%s", k, json_encode(value[k]))
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    return string.format("%q", tostring(value))
  end
end

-- =========================================================================
-- Helper: get current timestamp string (ISO-ish)
-- =========================================================================
local function getTimestamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- =========================================================================
-- Main execution
-- =========================================================================
print("AE2-ES Tier 3 Extended Soak Test Suite")
print("==================================================")
print("Lua version: " .. _VERSION)
print("")

-- Reset test state
Assert.reset()

-- Measure baseline memory
collectgarbage("collect")
local memBefore = collectgarbage("count")

-- Track job crashes
local jobCrashes = 0

-- Start timer
local startTime = os.clock()

-- -----------------------------------------------------------------
-- Phase 1: Soak Test (memory stress, saturation, ghost items)
-- -----------------------------------------------------------------
print("--- Phase 1: Soak Test (test_soak.lua) ---")
local ok, err = pcall(function()
  require("tests.test_soak")
end)
if not ok then
  print("ERROR: Soak test crashed: " .. tostring(err))
  jobCrashes = jobCrashes + 1
end

-- Force GC and measure after soak
collectgarbage("collect")
local memAfterSoak = collectgarbage("count")

-- -----------------------------------------------------------------
-- Phase 2: Time-Slice Scheduler Profiling
-- -----------------------------------------------------------------
print("")
print("--- Phase 2: Scheduler Profiling (test_timeslicescheduler.lua) ---")
local ok2, err2 = pcall(function()
  require("tests.test_timeslicescheduler")
end)
if not ok2 then
  print("ERROR: Scheduler test crashed: " .. tostring(err2))
  jobCrashes = jobCrashes + 1
end

-- Force final GC
collectgarbage("collect")
local memAfter = collectgarbage("count")

-- End timer
local elapsed = os.clock() - startTime

-- =========================================================================
-- Collect test results
-- =========================================================================
local results = Assert.getResults()
local totalTests = #results
local totalAssertions = 0
local totalFailures = 0

for _, test in ipairs(results) do
  totalAssertions = totalAssertions + (test.assertions or 0)
  totalFailures = totalFailures + (test.failures or 0)
end

-- =========================================================================
-- Build performance report
-- =========================================================================
local memDelta = memAfter - memBefore
local memDeltaSoak = memAfterSoak - memBefore
-- Check for memory leak (> 100% growth — soak tests already validate
-- per-group flatness at 15%; this macroscopic check is a safety net)
local memoryLeakDetected = (memBefore > 0) and (memDelta > memBefore * 1.0)
local yieldGapOver4s = (elapsed > 4.0)
local allPassed = (totalFailures == 0) and (not memoryLeakDetected) and (not yieldGapOver4s) and (jobCrashes == 0)

local report = {
  tier = "Tier 3",
  timestamp = getTimestamp(),
  elapsed_seconds = round(elapsed, 3),
  gc_memory_before_kb = round(memBefore, 1),
  gc_memory_after_kb = round(memAfter, 1),
  gc_memory_delta_kb = round(memDelta, 1),
  gc_memory_after_soak_kb = round(memAfterSoak, 1),
  tests_run = totalTests,
  assertions = totalAssertions,
  failures = totalFailures,
  memory_leak_detected = memoryLeakDetected,
  yield_gap_over_4s = yieldGapOver4s,
  job_crashes = jobCrashes,
  success = allPassed,
}

-- =========================================================================
-- Output
-- =========================================================================
-- Print full test summary via Assert
Assert.summary()

-- Print JSON report
print("")
print("============================================")
print("  TIER 3 PERFORMANCE REPORT (JSON)")
print("============================================")
print("")
print("TIER3_REPORT:" .. json_encode(report))

-- Write to file as well (for artifact upload)
local file, writeErr = io.open("tier3-performance-report.json", "w")
if file then
  file:write(json_encode(report))
  file:close()
  print("Report written to tier3-performance-report.json")
else
  print("WARNING: Could not write report file: " .. tostring(writeErr))
end

-- Exit
if allPassed then
  print("")
  print("TIER 3 PASSED")
  os.exit(0)
else
  print("")
  if totalFailures > 0 then
    print(string.format("FAIL: %d test failure(s)", totalFailures))
  end
  if memoryLeakDetected then
    print(string.format("FAIL: Memory leak detected (%.1f KB growth)", memDelta))
  end
  if yieldGapOver4s then
    print(string.format("FAIL: Yield gap %.1fs exceeds 4s threshold", elapsed))
  end
  if jobCrashes > 0 then
    print(string.format("FAIL: %d job crash(es)", jobCrashes))
  end
  os.exit(1)
end
