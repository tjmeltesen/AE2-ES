-- Test runner for AE2-ES unit tests
-- Usage: lua tests/run_tests.lua
-- Designed for both OC emulator and standalone Lua 5.3

local Assert = require("tests.helpers.assertions")

-- Find and run all test files
local testFiles = {
  "tests.test_jit_db_cleanup",
  "tests.test_telemetry_serialization",
  "tests.test_malformed_payload",
  "tests.test_soak",
  "tests.test_timeslicescheduler",
}

-- Setup package path to include project root
local projectRoot = arg and arg[0] and arg[0]:match("(.*[/\\])") or "."
projectRoot = projectRoot:gsub("[/\\]tests[/\\]?$", "")
if projectRoot == "." then projectRoot = "" end

if projectRoot ~= "" then
  package.path = projectRoot .. "/?.lua;" .. projectRoot .. "/?/init.lua;" .. package.path
end

-- Ensure src is on the path
package.path = "./src/?.lua;./?.lua;" .. package.path

print("AE2-ES Unit Test Suite")
print("======================")
print("Lua version: " .. _VERSION)
print("")

-- Run each test file
local totalPassed = 0
local totalFailed = 0

for _, testModule in ipairs(testFiles) do
  local ok, err = pcall(require, testModule)
  if not ok then
    print(string.format("  ERROR loading %s: %s", testModule, tostring(err)))
    totalFailed = totalFailed + 1
  end
end

-- Print summary
local success = Assert.summary()

-- Exit with appropriate code
if not success then
  os.exit(1)
else
  os.exit(0)
end
