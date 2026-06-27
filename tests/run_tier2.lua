-- =============================================================================
-- AE2-ES Tier 2 Integration Test Runner
-- =============================================================================
-- Runs the C3 integration test suite: modem broadcasting, HAL interfacing,
-- redstone lock synchronization, and fault injection/recovery.
--
-- Designed to run via lupa (LuaJIT embedded in Python) in CI.
-- Usage:
--   python run_tier2.py          (preferred — CI mode)
--   lua tests/run_tier2.lua      (standalone Lua 5.3)
-- =============================================================================

local Assert = require("tests.helpers.assertions")

-- Integration test files — C3 deliverables
local testFiles = {
  "tests.test_integration",        -- C3: modem/HAL/redstone/fault (G1–G4)
}

-- Optional: state transition integration tests (Tier 1.5 — cross-phase integration)
-- Uncomment to include in Tier 2 when those tests are ready:
-- "tests.test_state_transitions",

-- ===========================================================================
-- Setup package path
-- ===========================================================================
local projectRoot = arg and arg[0] and arg[0]:match("(.*[/\\])") or "."
projectRoot = projectRoot:gsub("[/\\]tests[/\\]?$", "")
if projectRoot == "." then projectRoot = "" end

if projectRoot ~= "" then
  package.path = projectRoot .. "/?.lua;" .. projectRoot .. "/?/init.lua;" .. package.path
end

-- Ensure source directories are on the path
package.path = "./src/?.lua;./?.lua;./supervisor/?.lua;./supervisor/?/init.lua;" .. package.path

-- ===========================================================================
-- Banner
-- ===========================================================================
print("")
print("┌──────────────────────────────────────────────┐")
print("│  AE2-ES Tier 2 — Integration Test Suite      │")
print("│  C3: Modem · HAL · Redstone · Fault Injection│")
print("└──────────────────────────────────────────────┘")
print("")
print("Lua version: " .. _VERSION)
print("Test files:  " .. #testFiles)
print("")

-- ===========================================================================
-- Run each integration test file
-- ===========================================================================
local totalPassed = 0
local totalFailed = 0

for _, testModule in ipairs(testFiles) do
  local ok, err = pcall(require, testModule)
  if not ok then
    print(string.format("  ERROR loading %s: %s", testModule, tostring(err)))
    totalFailed = totalFailed + 1
  end
end

-- ===========================================================================
-- Print summary
-- ===========================================================================
local success = Assert.summary()

-- Report outcome
if success then
  print("══ TIER 2 INTEGRATION: PASSED ══")
  print("")
  os.exit(0)
else
  print("══ TIER 2 INTEGRATION: FAILED ══")
  print("")
  os.exit(1)
end
