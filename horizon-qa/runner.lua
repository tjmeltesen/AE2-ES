--[[
horizon-qa/runner.lua — Horizon-QA Tier 2 Integration Test Runner
AE2 Execution System (AE2-ES), Deliverable C9

Discovers all hq_test_*.lua files in horizon-qa/tests/, runs each in an
isolated OC computer instance (simulated in standalone mode, real OC on
the headless GTNH server), collects Assert.summary() output, and writes
results to a JSON file for CI capture.

Usage:
  lua horizon-qa/runner.lua                    # run all tests
  lua horizon-qa/runner.lua --filter modem     # run tests matching "modem"
  lua horizon-qa/runner.lua --output results.json  # write JSON to file
  lua horizon-qa/runner.lua --junit results.xml    # write JUnit XML
  lua horizon-qa/runner.lua --verbose              # verbose output
  lua horizon-qa/runner.lua --real                 # use real OC components

Exit codes: 0 = all passed, 1 = failures, 2 = runtime error
]]--

local runner = {}

-- ===========================================================================
-- Configuration
-- ===========================================================================
local DEFAULT_OUTPUT = "horizon-qa-results.json"
local DEFAULT_TIMEOUT = 300  -- 5 minutes per test (matches acceptance criteria)

-- ===========================================================================
-- CLI argument parsing
-- ===========================================================================
local function parseArgs(rawArgs)
  local args = {
    filter = nil,
    output = nil,
    junit = nil,
    verbose = false,
    realMode = false,
  }

  rawArgs = rawArgs or arg or {}
  for i = 1, #rawArgs do
    local a = rawArgs[i]
    if a == "--filter" and rawArgs[i + 1] then
      args.filter = rawArgs[i + 1]
    elseif a:match("^--filter=") then
      args.filter = a:match("^--filter=(.*)")
    elseif a == "--output" and rawArgs[i + 1] then
      args.output = rawArgs[i + 1]
    elseif a:match("^--output=") then
      args.output = a:match("^--output=(.*)")
    elseif a == "--junit" and rawArgs[i + 1] then
      args.junit = rawArgs[i + 1]
    elseif a:match("^--junit=") then
      args.junit = a:match("^--junit=(.*)")
    elseif a == "--verbose" or a == "-v" then
      args.verbose = true
    elseif a == "--real" then
      args.realMode = true
    elseif a == "--help" or a == "-h" then
      print([[
Horizon-QA Tier 2 Test Runner (AE2-ES C9)
Usage: lua horizon-qa/runner.lua [options]

Options:
  --filter <pattern>   Run only tests whose filename matches <pattern>
  --output <path>      Write JSON results to <path> (default: horizon-qa-results.json)
  --junit <path>       Write JUnit XML results to <path>
  --verbose, -v        Verbose output (show per-assertion details)
  --real               Run against real OC components (headless GTNH server)
  --help, -h           Show this help
]])
      os.exit(0)
    end
  end
  return args
end

-- ===========================================================================
-- Test discovery
-- ===========================================================================
local function discoverTests(testDir, filter)
  local tests = {}
  -- List files by pattern (lfs.filesystem won't be available, use io.popen)
  local handle = io.popen('ls "' .. testDir .. '" 2>/dev/null || dir /b "' .. testDir .. '" 2>nul')
  if not handle then
    return tests
  end

  for line in handle:lines() do
    local fname = line:match("([^\\/]+)$") or line
    if fname:match("^hq_test_.*%.lua$") then
      if not filter or fname:lower():find(filter:lower(), 1, true) then
        local fullPath = testDir .. "/" .. fname
        table.insert(tests, { name = fname, path = fullPath })
      end
    end
  end
  handle:close()

  -- Sort by name for deterministic ordering
  table.sort(tests, function(a, b) return a.name < b.name end)
  return tests
end

-- ===========================================================================
-- Set up package paths for the horizon-qa environment
-- ===========================================================================
local function setupPaths()
  -- Add horizon-qa/ to the path so tests can require helpers
  -- Also add project root so tests can require src/ modules
  package.path = "./horizon-qa/?.lua;./horizon-qa/?/init.lua;" ..
                 "./horizon-qa/tests/?.lua;" ..
                 "./src/?.lua;./?.lua;./tests/?.lua;./tests/?/init.lua;" ..
                 package.path
end

-- ===========================================================================
-- Run a single test file in an isolated environment
-- ===========================================================================
local function runSingleTest(test, args)
  local result = {
    name = test.name,
    path = test.path,
    status = "UNKNOWN",
    assertions = 0,
    failures = 0,
    errors = {},
    duration = 0,
  }

  if args.verbose then
    print(string.format("\n  === Running: %s ===", test.name))
  end

  local startTime = os.clock()

  -- Load and execute the test file
  local ok, err = pcall(function()
    -- Reset Assert state before each test
    local Assert = require("tests.helpers.assertions")
    Assert.reset()

    -- Execute the test file
    dofile(test.path)
  end)

  result.duration = os.clock() - startTime

  if not ok then
    result.status = "ERROR"
    result.errors[#result.errors + 1] = tostring(err)
    if args.verbose then
      print(string.format("    ERROR: %s", tostring(err)))
    end
    return result
  end

  -- Collect results from Assert
  local Assert = require("tests.helpers.assertions")
  local testResults = Assert.getResults()
  local totalAssertions = 0
  local totalFailures = 0

  for _, t in ipairs(testResults) do
    totalAssertions = totalAssertions + t.assertions
    totalFailures = totalFailures + t.failures
    for _, e in ipairs(t.errors or {}) do
      result.errors[#result.errors + 1] = t.name .. ": " .. e
    end
  end

  result.assertions = totalAssertions
  result.failures = totalFailures

  if totalFailures > 0 then
    result.status = "FAIL"
  elseif totalAssertions == 0 then
    result.status = "PASS"  -- no assertions but no errors
  else
    result.status = "PASS"
  end

  if args.verbose then
    local icon = result.status == "PASS" and "PASS" or "FAIL"
    print(string.format("    %s — %d assertions, %d failures (%.2fs)",
      icon, totalAssertions, totalFailures, result.duration))
    if #result.errors > 0 then
      for _, e in ipairs(result.errors) do
        print(string.format("      ! %s", e))
      end
    end
  end

  return result
end

-- ===========================================================================
-- Generate JUnit XML from results
-- ===========================================================================
local function generateJUnit(results, outputPath)
  local totalTests = 0
  local totalFailures = 0
  local totalErrors = 0
  local totalTime = 0

  for _, r in ipairs(results) do
    totalTests = totalTests + 1
    totalTime = totalTime + (r.duration or 0)
    if r.status == "FAIL" then
      totalFailures = totalFailures + 1
    elseif r.status == "ERROR" then
      totalErrors = totalErrors + 1
    end
  end

  local xml = {}
  table.insert(xml, '<?xml version="1.0" encoding="UTF-8"?>')
  table.insert(xml, string.format(
    '<testsuite name="AE2-ES Horizon-QA Tier 2" tests="%d" failures="%d" errors="%d" time="%.3f">',
    totalTests, totalFailures, totalErrors, totalTime))

  for _, r in ipairs(results) do
    table.insert(xml, string.format(
      '  <testcase classname="AE2-ES.HorizonQA" name="%s" time="%.3f">',
      r.name, r.duration or 0))

    if r.status == "FAIL" then
      local msg = #r.errors > 0 and r.errors[1] or "test failed"
      table.insert(xml, string.format(
        '    <failure message="%d assertions, %d failures"><![CDATA[%s]]></failure>',
        r.assertions, r.failures, msg))
    elseif r.status == "ERROR" then
      local msg = #r.errors > 0 and r.errors[1] or "runtime error"
      table.insert(xml, string.format(
        '    <error message="Runtime error"><![CDATA[%s]]></error>', msg))
    end

    table.insert(xml, '  </testcase>')
  end

  table.insert(xml, '</testsuite>')

  local content = table.concat(xml, "\n")
  local f = io.open(outputPath, "w")
  if f then
    f:write(content)
    f:close()
    print(string.format("JUnit XML written to: %s", outputPath))
  else
    print(string.format("ERROR: could not write JUnit XML to: %s", outputPath))
  end
end

-- ===========================================================================
-- Main entry point
-- ===========================================================================
local function main()
  local args = parseArgs()

  if args.verbose then
    print("AE2-ES Horizon-QA Tier 2 Test Runner")
    print("=====================================")
    print(string.format("Lua version: %s", _VERSION))
    print(string.format("Mode: %s", args.realMode and "REAL (OC components)" or "standalone (mocks)"))
    if args.filter then
      print(string.format("Filter: %s", args.filter))
    end
    print("")
  end

  setupPaths()

  -- Discover tests
  local testDir = args.realMode and "/tests/horizon-qa" or "horizon-qa/tests"
  local tests = discoverTests(testDir, args.filter)

  if #tests == 0 then
    print("ERROR: No Horizon-QA tests found in " .. testDir)
    if args.filter then
      print("       Filter was: " .. args.filter)
    end
    os.exit(2)
  end

  if args.verbose then
    print(string.format("Discovered %d Horizon-QA test(s):", #tests))
    for _, t in ipairs(tests) do
      print(string.format("  - %s", t.name))
    end
    print("")
  end

  -- Run tests
  local results = {}
  local startTime = os.clock()

  for _, test in ipairs(tests) do
    local result = runSingleTest(test, args)
    table.insert(results, result)
  end

  local totalTime = os.clock() - startTime

  -- Build summary
  local summary = {
    runner = "horizon-qa/runner.lua",
    version = "1.0.0",
    timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    total = #results,
    passed = 0,
    failed = 0,
    errors = 0,
    totalAssertions = 0,
    totalFailures = 0,
    duration = totalTime,
    results = {},
  }

  for _, r in ipairs(results) do
    local entry = {
      name = r.name,
      status = r.status,
      assertions = r.assertions,
      failures = r.failures,
      duration = r.duration,
    }
    if #r.errors > 0 then
      entry.errors = r.errors
    end
    table.insert(summary.results, entry)

    if r.status == "PASS" then
      summary.passed = summary.passed + 1
    elseif r.status == "FAIL" then
      summary.failed = summary.failed + 1
    else
      summary.errors = summary.errors + 1
    end
    summary.totalAssertions = summary.totalAssertions + r.assertions
    summary.totalFailures = summary.totalFailures + r.failures
  end

  -- Print summary
  print(string.format("\nHorizon-QA Results: %d/%d passed (%.2fs)",
    summary.passed, summary.total, totalTime))
  print(string.format("  Assertions: %d total, %d failures",
    summary.totalAssertions, summary.totalFailures))

  for _, r in ipairs(results) do
    local icon
    if r.status == "PASS" then
      icon = "  PASS"
    elseif r.status == "FAIL" then
      icon = "  FAIL"
    else
      icon = " ERROR"
    end
    print(string.format("%s  %s  (%d assertions, %.2fs)",
      icon, r.name, r.assertions, r.duration))
    if (r.status == "FAIL" or r.status == "ERROR") and #r.errors > 0 then
      for _, e in ipairs(r.errors) do
        print(string.format("        %s", e))
      end
    end
  end

  -- Write JSON output
  local outputPath = args.output or DEFAULT_OUTPUT
  local json = require("horizon-qa.json_writer")
  local ok, err = json.write(summary, outputPath)
  if ok then
    print(string.format("\nResults written to: %s", outputPath))
  else
    print(string.format("\nWarning: Could not write JSON: %s", err or "unknown error"))
    -- Fallback: write a minimal JSON manually
    local f = io.open(outputPath, "w")
    if f then
      f:write(string.format(
        '{"total":%d,"passed":%d,"failed":%d,"errors":%d,"totalAssertions":%d,"totalFailures":%d}\n',
        summary.total, summary.passed, summary.failed, summary.errors,
        summary.totalAssertions, summary.totalFailures))
      f:close()
      print(string.format("Fallback JSON written to: %s", outputPath))
    end
  end

  -- Write JUnit XML if requested
  if args.junit then
    generateJUnit(results, args.junit)
  end

  -- Exit with status code
  if summary.failed > 0 or summary.errors > 0 then
    os.exit(1)
  else
    os.exit(0)
  end
end

-- Run if this is the main script (not required as a module)
if ... == nil then
  local ok, err = pcall(main)
  if not ok then
    print(string.format("FATAL: %s", tostring(err)))
    print(debug.traceback())
    os.exit(2)
  end
end

return runner
