-- JobManifest_test.lua
-- Unit tests for AE2-ES Module A1: JobManifest
-- Designed for OC Emulator (Tier 1) or standard Lua 5.2/5.3
--
-- Usage:
--   lua JobManifest_test.lua                  -- run all tests
--   lua JobManifest_test.lua test_new         -- run single test group
--   lua JobManifest_test.lua --verbose        -- full output

local JobManifest = dofile("JobManifest.lua")

-- Test harness -----------------------------------------------------------
local tests_run    = 0
local tests_passed = 0
local tests_failed = {}

local function assert_eq(a, b, msg)
  tests_run = tests_run + 1
  if a == b then
    tests_passed = tests_passed + 1
    if arg and arg[1] == "--verbose" then
      print("  PASS  " .. (msg or ""))
    end
  else
    local err = string.format("FAIL: %s  (expected %s, got %s)", msg or "", tostring(b), tostring(a))
    table.insert(tests_failed, err)
    print("  " .. err)
  end
end

local function assert_true(v, msg) assert_eq(v, true, msg) end
local function assert_false(v, msg) assert_eq(v, false, msg) end
local function assert_nil(v, msg) assert_eq(v, nil, msg) end
local function assert_not_nil(v, msg)
  tests_run = tests_run + 1
  if v ~= nil then
    tests_passed = tests_passed + 1
  else
    local err = string.format("FAIL: %s  (expected non-nil, got nil)", msg or "")
    table.insert(tests_failed, err)
    print("  " .. err)
  end
end

local function assert_empty(t, msg)
  tests_run = tests_run + 1
  if next(t) == nil then
    tests_passed = tests_passed + 1
  else
    local err = string.format("FAIL: %s  (expected empty table, got elements)", msg or "")
    table.insert(tests_failed, err)
    print("  " .. err)
  end
end

-- Test groups ------------------------------------------------------------

local function test_new()
  print("\n=== test_new ===")
  local m = JobManifest.new("job-1")
  assert_eq(m.id,              "job-1",    "jobId stored")
  assert_eq(m.status,          "BUFFERING", "initial status BUFFERING")
  assert_empty(m.inputs,             "inputs defaults to {}")
  assert_nil(m.assignedMachine,            "assignedMachine nil")
  assert_not_nil(m.createdAt,              "createdAt set")
  assert_eq(m.createdAt,       m.updatedAt, "createdAt == updatedAt initially")
  assert_nil(m.completedAt,                "completedAt nil")
  assert_nil(m.faultReason,                "faultReason nil")
  assert_empty(m.metadata,              "metadata empty")

  local inputs = { { name = "minecraft:iron_ingot", amount = 64 } }
  local m2 = JobManifest.new("job-2", inputs)
  assert_eq(m2.inputs, inputs, "inputs stored as-is")

  local ok, err = pcall(JobManifest.new, nil)
  assert_false(ok, "nil jobId raises assertion error")
end

local function test_updateState_valid()
  print("\n=== test_updateState_valid ===")
  local m = JobManifest.new("lifecycle")
  assert_true(m:updateState("LOGGING"),      "BUFFERING -> LOGGING")
  assert_eq(m.status, "LOGGING")
  assert_true(m:updateState("ALLOCATING"),    "LOGGING -> ALLOCATING")
  assert_eq(m.status, "ALLOCATING")
  assert_true(m:updateState("TRANSFERRING"),  "ALLOCATING -> TRANSFERRING")
  assert_eq(m.status, "TRANSFERRING")
  assert_true(m:updateState("PROCESSING"),    "TRANSFERRING -> PROCESSING")
  assert_eq(m.status, "PROCESSING")
  assert_true(m:updateState("CLEANUP"),       "PROCESSING -> CLEANUP")
  assert_eq(m.status, "CLEANUP")
  assert_true(m:updateState("COMPLETED"),     "CLEANUP -> COMPLETED")
  assert_eq(m.status, "COMPLETED")
  assert_not_nil(m.completedAt,              "completedAt set on COMPLETED")
  assert_true(m:isTerminal(),                "COMPLETED is terminal")
end

local function test_updateState_invalid()
  print("\n=== test_updateState_invalid ===")
  local m = JobManifest.new("skip-test")
  assert_false(m:updateState("PROCESSING"),   "BUFFERING -> PROCESSING rejected")
  assert_eq(m.status, "BUFFERING")

  m:updateState("LOGGING")
  assert_false(m:updateState("BUFFERING"),    "backward rejected")
  assert_false(m:updateState("OHNO"),         "unknown state rejected")

  local m2 = JobManifest.new("done")
  m2:updateState("LOGGING")
  m2:updateState("ALLOCATING")
  m2:updateState("TRANSFERRING")
  m2:updateState("PROCESSING")
  m2:updateState("CLEANUP")
  m2:updateState("COMPLETED")
  assert_false(m2:updateState("FAULTED"),     "terminal locked")
end

local function test_updateState_from_faulted()
  print("\n=== test_updateState_from_faulted ===")
  local m = JobManifest.new("faulted")
  m:fault("Test")
  assert_false(m:updateState("CLEANUP"),     "FAULTED -> CLEANUP rejected")
  assert_false(m:updateState("COMPLETED"),   "FAULTED -> COMPLETED rejected")
end

local function test_fault()
  print("\n=== test_fault ===")
  local m = JobManifest.new("fault-me")
  assert_true(m:fault("Power failure"))
  assert_eq(m.status, "FAULTED")
  assert_eq(m.faultReason, "Power failure")
  assert_true(m:isTerminal())

  local m2 = JobManifest.new("fault-late")
  m2:updateState("LOGGING")
  m2:updateState("ALLOCATING")
  assert_true(m2:fault("Allocation timeout"))
  assert_eq(m2.status, "FAULTED")

  assert_false(m:fault("Again"))
  assert_eq(m.faultReason, "Power failure")
end

local function test_fault_default_reason()
  print("\n=== test_fault_default_reason ===")
  local m = JobManifest.new("no-reason")
  m:fault()
  assert_eq(m.faultReason, "Unknown fault")
end

local function test_bindHardware()
  print("\n=== test_bindHardware ===")
  local m = JobManifest.new("bind-me")
  assert_false(m:bindHardware("m1"), "BUFFERING rejected")
  m:updateState("LOGGING")
  assert_false(m:bindHardware("m1"), "LOGGING rejected")
  m:updateState("ALLOCATING")
  assert_true(m:bindHardware("m1"),  "ALLOCATING ok")
  assert_eq(m.assignedMachine, "m1")
  assert_false(m:bindHardware("m2"), "second bind rejected")
  m:updateState("TRANSFERRING")
  assert_false(m:bindHardware("m3"), "TRANSFERRING rejected")
end

local function test_unbindHardware()
  print("\n=== test_unbindHardware ===")
  local m = JobManifest.new("unbind-me")
  m:updateState("LOGGING")
  m:updateState("ALLOCATING")
  m:bindHardware("mx")
  assert_true(m:unbindHardware())
  assert_nil(m.assignedMachine)
  assert_false(m:unbindHardware())
end

local function test_isStale()
  print("\n=== test_isStale ===")
  local m = JobManifest.new("fresh")
  assert_false(m:isStale(), "new not stale")

  local m2 = JobManifest.new("done")
  m2:updateState("LOGGING")
  m2:updateState("ALLOCATING")
  m2:updateState("TRANSFERRING")
  m2:updateState("PROCESSING")
  m2:updateState("CLEANUP")
  m2:updateState("COMPLETED")
  assert_false(m2:isStale(os.time()+9999), "COMPLETED never stale")

  local m3 = JobManifest.new("fd")
  m3:fault("x")
  assert_false(m3:isStale(os.time()+9999), "FAULTED never stale")

  local m4 = JobManifest.new("old")
  assert_true(m4:isStale(os.time()+9999), "future time is stale")

  -- Per-state timeout: BUFFERING=120s
  local now = os.time()
  m4.updatedAt = now - 121
  assert_true(m4:isStale(now), "stale after 121s in BUFFERING")
end

local function test_setStaleTimeout()
  print("\n=== test_setStaleTimeout ===")
  local m = JobManifest.new("t")
  m:setStaleTimeout(10)
  m.updatedAt = os.time() - 11
  assert_true(m:isStale(os.time()), "10s timeout")
  local ok, err = pcall(m.setStaleTimeout, m, 0)
  assert_false(ok)
end

local function test_isTerminal()
  print("\n=== test_isTerminal ===")
  local states = {"BUFFERING","LOGGING","ALLOCATING","TRANSFERRING","PROCESSING","CLEANUP"}
  for _, s in ipairs(states) do
    local m = JobManifest.new(s)
    m.status = s
    assert_false(m:isTerminal(), s .. " not terminal")
  end
  local mc = JobManifest.new("c"); mc.status = "COMPLETED"; assert_true(mc:isTerminal())
  local mf = JobManifest.new("f"); mf.status = "FAULTED";  assert_true(mf:isTerminal())
end

local function test_age()
  print("\n=== test_age ===")
  local m = JobManifest.new("age")
  assert_true(m:age() >= 0)
end

local function test_metadata()
  print("\n=== test_metadata ===")
  local m = JobManifest.new("meta")
  m:setMeta("recipe", "iron_ingot")
  assert_eq(m:getMeta("recipe"), "iron_ingot")
  assert_nil(m:getMeta("missing"))
end

local function test_summarize()
  print("\n=== test_summarize ===")
  local m = JobManifest.new("s", {{name="ore",amount=8}})
  m:updateState("LOGGING")
  local s = m:summarize()
  assert_eq(s.id, "s")
  assert_eq(s.status, "LOGGING")
  assert_eq(#s.inputs, 1)
  assert_eq(s.isStale, false)
  assert_eq(s.isTerminal, false)
end

local function test_chained_full_lifecycle()
  print("\n=== test_chained_full_lifecycle ===")
  local m = JobManifest.new("chain")
  assert_true(m:updateState("LOGGING"))
  assert_true(m:updateState("ALLOCATING"))
  m:bindHardware("m42")
  assert_eq(m.assignedMachine, "m42")
  assert_true(m:updateState("TRANSFERRING"))
  assert_true(m:updateState("PROCESSING"))
  assert_true(m:updateState("CLEANUP"))
  assert_true(m:updateState("COMPLETED"))
  assert_true(m:isTerminal())
  assert_not_nil(m.completedAt)
end

-- Main runner ------------------------------------------------------------
local function run_all()
  local groups = {
    test_new,
    test_updateState_valid,
    test_updateState_invalid,
    test_updateState_from_faulted,
    test_fault,
    test_fault_default_reason,
    test_bindHardware,
    test_unbindHardware,
    test_isStale,
    test_setStaleTimeout,
    test_isTerminal,
    test_age,
    test_metadata,
    test_summarize,
    test_chained_full_lifecycle,
  }

  local filter = arg and arg[1]
  if filter and filter ~= "--verbose" then
    for _, fn in ipairs(groups) do
      if tostring(fn):match(filter) then
        fn()
      end
    end
  else
    for _, fn in ipairs(groups) do
      fn()
    end
  end

  print(string.format("\n=== Results: %d/%d passed, %d failed ===",
    tests_passed, tests_run, #tests_failed))
  if #tests_failed > 0 then
    print("Failures:")
    for _, f in ipairs(tests_failed) do
      print("  " .. f)
    end
    os.exit(1)
  end
end

run_all()
