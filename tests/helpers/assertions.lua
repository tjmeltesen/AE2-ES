-- Lightweight assertion library for unit tests
-- Works in both OC emulator and standalone Lua 5.3

local Assert = {}
local _testResults = {}
local _currentTest = nil

-- ANSI color codes (terminal-safe fallback)
local GREEN = "\27[32m"
local RED   = "\27[31m"
local YELLOW = "\27[33m"
local RESET = "\27[0m"

--- Start a new test
function Assert.startTest(name)
  _currentTest = { name = name, assertions = 0, failures = 0, errors = {} }
end

--- End the current test and record results
function Assert.endTest()
  if _currentTest then
    table.insert(_testResults, _currentTest)
    _currentTest = nil
  end
end

--- Internal: record a failure
local function recordFailure(msg)
  if _currentTest then
    _currentTest.failures = _currentTest.failures + 1
    table.insert(_currentTest.errors, msg)
  end
end

--- Assert two values are equal
function Assert.equal(expected, actual, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if expected ~= actual then
    local errMsg = msg or string.format("expected %s, got %s",
      tostring(expected), tostring(actual))
    recordFailure(errMsg)
    return false
  end
  return true
end

--- Assert value is truthy
function Assert.isTrue(value, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if not value then
    recordFailure(msg or "expected truthy value, got " .. tostring(value))
    return false
  end
  return true
end

--- Assert value is falsy
function Assert.isFalse(value, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if value then
    recordFailure(msg or "expected falsy value, got " .. tostring(value))
    return false
  end
  return true
end

--- Assert value is nil
function Assert.isNil(value, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if value ~= nil then
    recordFailure(msg or "expected nil, got " .. tostring(value))
    return false
  end
  return true
end

--- Assert value is not nil
function Assert.notNil(value, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if value == nil then
    recordFailure(msg or "expected non-nil value")
    return false
  end
  return true
end

--- Assert type of value
function Assert.type(expectedType, value, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if type(value) ~= expectedType then
    recordFailure(msg or string.format("expected type '%s', got '%s'",
      expectedType, type(value)))
    return false
  end
  return true
end

--- Assert table is empty
function Assert.tableEmpty(tbl, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if type(tbl) ~= "table" then
    recordFailure(msg or "expected table, got " .. type(tbl))
    return false
  end
  if next(tbl) ~= nil then
    recordFailure(msg or "expected empty table")
    return false
  end
  return true
end

--- Assert table has a specific key
function Assert.hasKey(tbl, key, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if type(tbl) ~= "table" then
    recordFailure(msg or "expected table")
    return false
  end
  if tbl[key] == nil then
    recordFailure(msg or "expected key '" .. tostring(key) .. "' in table")
    return false
  end
  return true
end

--- Assert a function throws an error
function Assert.throws(fn, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  local ok, err = pcall(fn)
  if ok then
    recordFailure(msg or "expected function to throw, but it succeeded")
    return false
  end
  return true
end

--- Assert two strings match
function Assert.match(pattern, str, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if not string.find(tostring(str), pattern) then
    recordFailure(msg or string.format("expected '%s' to match '%s'",
      tostring(str), pattern))
    return false
  end
  return true
end

--- Assert a value is greater than another
function Assert.greaterThan(expected, actual, msg)
  if _currentTest then
    _currentTest.assertions = _currentTest.assertions + 1
  end
  if not (actual > expected) then
    recordFailure(msg or string.format("expected %s > %s",
      tostring(actual), tostring(expected)))
    return false
  end
  return true
end

--- Get all test results
function Assert.getResults()
  return _testResults
end

--- Reset all results (for re-run)
function Assert.reset()
  _testResults = {}
  _currentTest = nil
end

--- Print a summary of all test results
function Assert.summary()
  local total = #_testResults
  local passed = 0
  local failed = 0
  local totalAssertions = 0
  local totalFailures = 0

  for _, test in ipairs(_testResults) do
    totalAssertions = totalAssertions + test.assertions
    totalFailures = totalFailures + test.failures
    if test.failures == 0 then
      passed = passed + 1
    else
      failed = failed + 1
    end
  end

  print(string.format("\n%s══════════════════════════════════════%s", YELLOW, RESET))
  print(string.format("%s  TEST RESULTS%s", YELLOW, RESET))
  print(string.format("%s══════════════════════════════════════%s", YELLOW, RESET))
  print(string.format("  Tests:    %d total, %s%d passed%s, %s%d failed%s",
    total, GREEN, passed, RESET, (failed > 0 and RED or ""), failed, RESET))
  print(string.format("  Asserts:  %d total, %d failures",
    totalAssertions, totalFailures))
  print("")

  for _, test in ipairs(_testResults) do
    local status = (test.failures == 0) and (GREEN .. "PASS" .. RESET) or (RED .. "FAIL" .. RESET)
    print(string.format("  [%s] %s (%d assertions)",
      status, test.name, test.assertions))
    for _, err in ipairs(test.errors) do
      print(string.format("    %s✗%s %s", RED, RESET, err))
    end
  end

  print("")
  return failed == 0
end

return Assert
