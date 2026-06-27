-- test_jit_db_cleanup.lua
-- Phase A: Assert JIT DB tables nilled on Job Complete.
-- Tests that all JIT-allocated tables in JobManifest are properly
-- set to nil after completion, preventing memory leaks across job cycles.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

local JobManifest = require("src.jobmanifest")
local BufferSnapshot = require("src.buffersnapshot")

-- ============================================================
-- Test Group 1: Single Job JIT Table Cleanup
-- ============================================================

-- Test 1.1: All JIT tables are non-nil after creation
Assert.startTest("JIT tables exist after JobManifest creation")
do
  local job = JobManifest.new("test-job-001", {iron = 64, copper = 32})
  local jit = job:getJITTables()
  Assert.notNil(jit._inputRegistry, "_inputRegistry should exist after creation")
  Assert.notNil(jit._hardwareBinds, "_hardwareBinds should exist after creation")
  Assert.notNil(jit._transferPlan, "_transferPlan should exist after creation")
  Assert.notNil(jit._processingLog, "_processingLog should exist after creation")
  Assert.notNil(jit._errorLog, "_errorLog should exist after creation")
  Assert.type("table", jit._inputRegistry, "_inputRegistry should be a table")
  Assert.type("table", jit._hardwareBinds, "_hardwareBinds should be a table")
  Assert.type("table", jit._transferPlan, "_transferPlan should be a table")
  Assert.type("table", jit._processingLog, "_processingLog should be a table")
  Assert.type("table", jit._errorLog, "_errorLog should be a table")
end
Assert.endTest()

-- Test 1.2: isJITCleaned returns false before completion
Assert.startTest("isJITCleaned returns false before complete()")
do
  local job = JobManifest.new("test-job-002", {steel = 16})
  Assert.isFalse(job:isJITCleaned(), "JIT should NOT be cleaned before complete()")
end
Assert.endTest()

-- Test 1.3: complete() sets all JIT tables to nil
Assert.startTest("complete() nils all JIT tables")
do
  local job = JobManifest.new("test-job-003", {gold = 8})
  job:complete()
  Assert.isTrue(job:isJITCleaned(), "All JIT tables should be nilled after complete()")
  Assert.isNil(job._inputRegistry, "_inputRegistry should be nil after complete()")
  Assert.isNil(job._hardwareBinds, "_hardwareBinds should be nil after complete()")
  Assert.isNil(job._transferPlan, "_transferPlan should be nil after complete()")
  Assert.isNil(job._processingLog, "_processingLog should be nil after complete()")
  Assert.isNil(job._errorLog, "_errorLog should be nil after complete()")
end
Assert.endTest()

-- Test 1.4: complete() transitions state to COMPLETE
Assert.startTest("complete() sets state to COMPLETE")
do
  local job = JobManifest.new("test-job-004", {diamond = 1})
  Assert.equal(JobManifest.STATE.BUFFERING, job.state, "Initial state should be BUFFERING")
  job:complete()
  Assert.equal(JobManifest.STATE.COMPLETE, job.state, "State should be COMPLETE after complete()")
end
Assert.endTest()

-- Test 1.5: getJITTables returns nil values after complete()
Assert.startTest("getJITTables returns nil values after complete()")
do
  local job = JobManifest.new("test-job-005", {coal = 128})
  job:complete()
  local jit = job:getJITTables()
  Assert.isNil(jit._inputRegistry, "getJITTables should return nil for _inputRegistry")
  Assert.isNil(jit._hardwareBinds, "getJITTables should return nil for _hardwareBinds")
  Assert.isNil(jit._transferPlan, "getJITTables should return nil for _transferPlan")
  Assert.isNil(jit._processingLog, "getJITTables should return nil for _processingLog")
  Assert.isNil(jit._errorLog, "getJITTables should return nil for _errorLog")
end
Assert.endTest()

-- ============================================================
-- Test Group 2: JIT Tables Populated Before Cleanup
-- ============================================================

-- Test 2.1: _inputRegistry accumulates registered inputs
Assert.startTest("_inputRegistry accumulates registered inputs")
do
  local job = JobManifest.new("test-job-006")
  job:registerInput("iron_ingot", 64)
  job:registerInput("copper_ingot", 32)
  job:registerInput("iron_ingot", 64) -- duplicate should accumulate
  Assert.equal(128, job._inputRegistry["iron_ingot"], "iron_ingot should total 128")
  Assert.equal(32, job._inputRegistry["copper_ingot"], "copper_ingot should be 32")
end
Assert.endTest()

-- Test 2.2: _hardwareBinds stores machine bindings
Assert.startTest("_hardwareBinds stores machine bindings")
do
  local job = JobManifest.new("test-job-007")
  local mockMachine = {address = "abc-123", type = "gt_machine", status = "AVAILABLE"}
  job:bindHardware(1, mockMachine)
  job:bindHardware(2, mockMachine)
  Assert.notNil(job._hardwareBinds[1], "Machine 1 should be bound")
  Assert.notNil(job._hardwareBinds[2], "Machine 2 should be bound")
  Assert.equal(mockMachine, job._hardwareBinds[1], "Machine 1 should reference mock")
end
Assert.endTest()

-- Test 2.3: _transferPlan stores transfer operations
Assert.startTest("_transferPlan stores transfer operations")
do
  local job = JobManifest.new("test-job-008")
  job:addTransfer({from = "buffer", to = "machine_1", item = "iron_ingot", count = 64})
  job:addTransfer({from = "buffer", to = "machine_2", item = "copper_ingot", count = 32})
  Assert.equal(2, #job._transferPlan, "transferPlan should have 2 entries")
  Assert.equal("iron_ingot", job._transferPlan[1].item, "First transfer should be iron")
end
Assert.endTest()

-- Test 2.4: _processingLog records per-machine events
Assert.startTest("_processingLog records per-machine events")
do
  local job = JobManifest.new("test-job-009")
  job:logProcessing(1, {type = "START", timestamp = os.time()})
  job:logProcessing(1, {type = "PROGRESS", timestamp = os.time()})
  job:logProcessing(2, {type = "START", timestamp = os.time()})
  Assert.equal(2, #job._processingLog[1], "Machine 1 should have 2 events")
  Assert.equal(1, #job._processingLog[2], "Machine 2 should have 1 event")
end
Assert.endTest()

-- Test 2.5: _errorLog records errors
Assert.startTest("_errorLog records errors")
do
  local job = JobManifest.new("test-job-010")
  job:logError({code = "MACHINE_FAULT", machine = 2, message = "overheat"})
  Assert.equal(1, #job._errorLog, "Error log should have 1 entry")
  Assert.equal("MACHINE_FAULT", job._errorLog[1].code, "Error code should match")
end
Assert.endTest()

-- Test 2.6: All populated JIT tables are nilled on complete()
Assert.startTest("Populated JIT tables are nilled on complete()")
do
  local job = JobManifest.new("test-job-011")
  job:registerInput("steel", 32)
  job:bindHardware(1, {address = "xyz"})
  job:addTransfer({from = "a", to = "b"})
  job:logProcessing(1, {type = "START"})
  job:logError({code = "TEST"})

  -- Verify populated
  Assert.notNil(job._inputRegistry["steel"], "Input should be registered")
  Assert.notNil(job._hardwareBinds[1], "Hardware should be bound")
  Assert.equal(1, #job._transferPlan, "Transfer should be planned")
  Assert.equal(1, #job._errorLog, "Error should be logged")

  -- Complete and verify cleanup
  job:complete()
  Assert.isNil(job._inputRegistry, "_inputRegistry should be nil after complete()")
  Assert.isNil(job._hardwareBinds, "_hardwareBinds should be nil after complete()")
  Assert.isNil(job._transferPlan, "_transferPlan should be nil after complete()")
  Assert.isNil(job._processingLog, "_processingLog should be nil after complete()")
  Assert.isNil(job._errorLog, "_errorLog should be nil after complete()")
end
Assert.endTest()

-- ============================================================
-- Test Group 3: Multiple Job Cycles — No Memory Leak
-- ============================================================

-- Test 3.1: Sequential jobs each clean up independently
Assert.startTest("Sequential jobs clean up independently")
do
  for i = 1, 5 do
    local job = JobManifest.new("cycle-" .. i, {ore = i * 16})
    job:registerInput("ore", i * 16)
    job:bindHardware(1, {idx = i})
    job:complete()
    Assert.isTrue(job:isJITCleaned(), "Job " .. i .. " should be cleaned")
  end
end
Assert.endTest()

-- Test 3.2: Large job cycle does not leak memory
Assert.startTest("Large job does not leak (all JIT nilled)")
do
  local job = JobManifest.new("large-job", {
    iron = 1000, copper = 1000, tin = 500, gold = 100, diamond = 10
  })

  -- Populate heavily
  for i = 1, 100 do
    job:registerInput("item_" .. i, math.random(1, 64))
    job:bindHardware(i, {address = "machine_" .. i})
    job:addTransfer({from = "buf", to = "mach_" .. i, count = i})
    job:logProcessing(i, {type = "START", time = os.time()})
  end

  -- Verify tables have content
  Assert.greaterThan(0, #job._transferPlan, "transferPlan should have entries")

  -- Complete
  job:complete()
  Assert.isTrue(job:isJITCleaned(), "All JIT tables should be nil after large job")
end
Assert.endTest()

-- ============================================================
-- Test Group 4: Edge Cases
-- ============================================================

-- Test 4.1: Double complete() is idempotent
Assert.startTest("Double complete() is idempotent")
do
  local job = JobManifest.new("double-complete", {wood = 64})
  job:complete()
  Assert.isTrue(job:isJITCleaned(), "First complete should clean")
  -- Second complete should not error
  local ok, err = pcall(function() job:complete() end)
  Assert.isTrue(ok, "Second complete() should not throw: " .. tostring(err))
  Assert.isTrue(job:isJITCleaned(), "Should still be clean after second complete")
end
Assert.endTest()

-- Test 4.2: fault() does NOT nil JIT tables (preserves for diagnostics)
Assert.startTest("fault() preserves JIT tables for diagnostics")
do
  local job = JobManifest.new("fault-job", {uranium = 8})
  job:registerInput("uranium", 8)
  job:logError({code = "CRITICAL_FAULT", message = "machine explosion"})
  job:fault()
  Assert.equal(JobManifest.STATE.FAULTED, job.state, "State should be FAULTED")
  Assert.isFalse(job:isJITCleaned(), "JIT should NOT be cleaned on fault() — diagnostics needed")
  Assert.notNil(job._errorLog, "Error log should be preserved for diagnostics")
  Assert.equal(1, #job._errorLog, "Error log should have 1 entry")
end
Assert.endTest()

-- Test 4.3: Empty job cleans up correctly
Assert.startTest("Empty job cleans up correctly")
do
  local job = JobManifest.new("empty-job")
  Assert.tableEmpty(job._inputRegistry, "Input registry should be empty")
  Assert.tableEmpty(job._transferPlan, "Transfer plan should be empty")
  job:complete()
  Assert.isTrue(job:isJITCleaned(), "Empty job should still nil all tables")
end
Assert.endTest()

-- Test 4.4: JIT tables are independent between jobs
Assert.startTest("JIT tables are independent between job instances")
do
  local jobA = JobManifest.new("job-a", {iron = 64})
  local jobB = JobManifest.new("job-b", {copper = 32})

  jobA:registerInput("iron", 64)
  jobB:registerInput("copper", 32)

  -- Verify independence
  Assert.equal(64, jobA._inputRegistry["iron"], "Job A should have iron")
  Assert.isNil(jobA._inputRegistry["copper"], "Job A should NOT have copper")
  Assert.equal(32, jobB._inputRegistry["copper"], "Job B should have copper")
  Assert.isNil(jobB._inputRegistry["iron"], "Job B should NOT have iron")

  -- Clean up job A only
  jobA:complete()
  Assert.isTrue(jobA:isJITCleaned(), "Job A should be cleaned")
  Assert.isFalse(jobB:isJITCleaned(), "Job B should NOT be affected by Job A cleanup")
  Assert.equal(32, jobB._inputRegistry["copper"], "Job B copper should still exist")
end
Assert.endTest()

-- Test 4.5: BufferSnapshot conversion produces cleanable JobManifest
Assert.startTest("BufferSnapshot→JobManifest conversion produces cleanable jobs")
do
  local buffer = {
    iron = {label = "Iron Ingot", size = 64},
    copper = {label = "Copper Ingot", size = 32},
  }
  local snapshot = BufferSnapshot.new(buffer)
  local job = snapshot:convertToManifest(JobManifest, "bs-test-001")

  Assert.notNil(job, "convertToManifest should return a job")
  Assert.equal(JobManifest.STATE.LOGGING, job.state, "Job should be in LOGGING state")
  Assert.notNil(job._inputRegistry["iron"], "Iron should be registered")
  Assert.notNil(job._inputRegistry["copper"], "Copper should be registered")

  -- After conversion, the job should be cleanable
  job:complete()
  Assert.isTrue(job:isJITCleaned(), "Converted job should clean up correctly")
end
Assert.endTest()

-- Test 4.6: isStale returns true after completion
Assert.startTest("isStale returns true after COMPLETE or FAULTED")
do
  local job = JobManifest.new("stale-test", {cobble = 64})
  Assert.isFalse(job:isStale(), "Active job should not be stale")
  job:complete()
  Assert.isTrue(job:isStale(), "Completed job should be stale")

  local job2 = JobManifest.new("stale-test-2", {dirt = 64})
  job2:fault()
  Assert.isTrue(job2:isStale(), "Faulted job should be stale")
end
Assert.endTest()
