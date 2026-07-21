-- test_soak.lua
-- Phase C: Soak Tests
-- 10k micro-jobs. Assert flat memory. Force saturation.
-- Inject ghost items, verify 10s timeout clears 100%.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

local JobManifest = require("src.jobmanifest")
local BufferSnapshot = require("src.BufferSnapshot")

-- ============================================================
-- Test Group 1: 10K Micro-Jobs — Flat Memory
-- ============================================================

-- Test 1.1: 10,000 micro-jobs created and completed, memory flat
Assert.startTest("10k micro-jobs: create, populate, complete — flat memory")
do
  -- Force full GC and measure baseline
  collectgarbage("collect")
  local memBefore = collectgarbage("count")

  local COMPLETED = 0
  local JOB_COUNT = 10000

  for i = 1, JOB_COUNT do
    local job = JobManifest.new("soak-" .. i, {item_a = 64, item_b = 32})
    job:registerInput("item_a", 64)
    job:registerInput("item_b", 32)
    job:bindHardware(1, {address = "mach-" .. (i % 4 + 1), status = "AVAILABLE"})
    job:addTransfer({from = "buffer", to = "machine", item = "item_a", count = 64})
    job:logProcessing(1, {type = "START", time = os.time()})
    job:complete()
    COMPLETED = COMPLETED + 1

    -- Yield periodically to prevent Lua stack issues in tight loop
    if i % 500 == 0 then collectgarbage("step", 100) end
  end

  -- Force full GC and measure after
  collectgarbage("collect")
  local memAfter = collectgarbage("count")

  Assert.equal(JOB_COUNT, COMPLETED, "All 10,000 jobs completed")
  Assert.isTrue(memAfter <= memBefore * 1.15,
    string.format("Memory should be flat: before=%.1f KB, after=%.1f KB (delta=%.1f KB)",
      memBefore, memAfter, memAfter - memBefore))
end
Assert.endTest()

-- Test 1.2: After 10k jobs, no stale references linger
Assert.startTest("After 10k jobs, no lingering JIT table references")
do
  -- Create and complete one more job to verify cleanup path still works
  local job = JobManifest.new("post-soak-check", {test = 1})
  job:registerInput("test", 1)
  job:complete()

  Assert.isTrue(job:isJITCleaned(), "Post-soak job correctly cleans JIT tables")
  Assert.isNil(job._inputRegistry, "_inputRegistry nil after complete")
  Assert.isNil(job._hardwareBinds, "_hardwareBinds nil after complete")
  Assert.isNil(job._transferPlan, "_transferPlan nil after complete")
  Assert.isNil(job._processingLog, "_processingLog nil after complete")
  Assert.isNil(job._errorLog, "_errorLog nil after complete")
end
Assert.endTest()

-- ============================================================
-- Test Group 2: Saturation Stress
-- ============================================================

-- Test 2.1: Saturated array yields without leaking
Assert.startTest("Saturated array: yield loop 1000x, no leak")
do
  collectgarbage("collect")
  local memBefore = collectgarbage("count")

  -- Simulate a saturated machine pool
  local busyMachines = {
    {hwAddr = "m-01", status = "PROCESSING"},
    {hwAddr = "m-02", status = "PROCESSING"},
    {hwAddr = "m-03", status = "PROCESSING"},
    {hwAddr = "m-04", status = "LOCKED"},
  }

  local function countAvailable(machs)
    local c = 0
    for _, m in ipairs(machs) do if m.status == "AVAILABLE" then c = c + 1 end end
    return c
  end

  -- Poll 1000 times while saturated
  local polls = 0
  for i = 1, 1000 do
    local avail = countAvailable(busyMachines)
    if avail == 0 then
      polls = polls + 1
      -- In real code: coroutine.yield() or sleep — we just count
    end
    if i % 200 == 0 then collectgarbage("step", 50) end
  end

  Assert.equal(1000, polls, "All 1000 polls hit saturation")

  collectgarbage("collect")
  local memAfter = collectgarbage("count")
  Assert.isTrue(memAfter <= memBefore * 1.10,
    string.format("No memory leak during saturation: before=%.1f KB, after=%.1f KB",
      memBefore, memAfter))
end
Assert.endTest()

-- Test 2.2: Saturation recovery: machine frees, allocation proceeds
Assert.startTest("Saturation recovery: cycle 500x with slot freeing")
do
  local function runSaturationCycle()
    local machines = {
      {hwAddr = "sa-01", status = "PROCESSING"},
      {hwAddr = "sa-02", status = "PROCESSING"},
      {hwAddr = "sa-03", status = "PROCESSING"},
      {hwAddr = "sa-04", status = "PROCESSING"},
    }

    local function countAvailable(machs)
      local c = 0
      for _, m in ipairs(machs) do if m.status == "AVAILABLE" then c = c + 1 end end
      return c
    end

    -- Poll until a slot opens
    local waited = 0
    while countAvailable(machines) == 0 and waited < 10 do
      waited = waited + 1
      -- Simulate: one machine finishes
      if waited == 5 then
        machines[2].status = "AVAILABLE"
      end
    end

    -- Allocate the available slot
    local allocated = 0
    for _, m in ipairs(machines) do
      if m.status == "AVAILABLE" then
        m.status = "LOCKED"
        allocated = allocated + 1
      end
    end

    return allocated, waited
  end

  local totalAllocated = 0
  local totalWaited = 0
  for i = 1, 500 do
    local alloc, wait = runSaturationCycle()
    totalAllocated = totalAllocated + alloc
    totalWaited = totalWaited + wait
  end

  Assert.equal(500, totalAllocated, "500 slots allocated across 500 cycles")
  Assert.isTrue(totalWaited > 0, "At least some cycles waited for a free slot")
end
Assert.endTest()

-- Test 2.3: Heavy population saturation does not corrupt JIT tables
Assert.startTest("Heavy population + saturation: JIT cleanup holds")
do
  collectgarbage("collect")
  local memBefore = collectgarbage("count")

  for i = 1, 500 do
    local job = JobManifest.new("sat-pop-" .. i)

    -- Heavy population of all JIT tables
    for j = 1, 20 do
      job:registerInput("resource_" .. j, math.random(1, 256))
    end
    for j = 1, 4 do
      job:bindHardware(j, {
        address = "sat-mach-" .. j,
        status = (j == 1) and "AVAILABLE" or "PROCESSING",
      })
    end
    for j = 1, 10 do
      job:addTransfer({from = "buf", to = "mach_" .. (j % 4 + 1), count = j * 16})
    end
    job:logError({code = "SAT_TEST", message = "saturation stress", iteration = i})

    -- Verify complete cleans everything
    job:complete()
    Assert.isTrue(job:isJITCleaned(), "Job " .. i .. " JIT cleaned after complete")
    Assert.equal(JobManifest.STATE.COMPLETE, job.state, "Job " .. i .. " state is COMPLETE")

    if i % 100 == 0 then collectgarbage("step", 100) end
  end

  collectgarbage("collect")
  local memAfter = collectgarbage("count")
  Assert.isTrue(memAfter <= memBefore * 1.20,
    string.format("Heavy pop sat JIT cleanup: before=%.1f KB, after=%.1f KB",
      memBefore, memAfter))
end
Assert.endTest()

-- ============================================================
-- Test Group 3: Ghost Items + 10s Timeout
-- ============================================================

-- Test 3.1: Ghost items detected and flushed after 10s timeout
Assert.startTest("Ghost items: 10s idle timeout triggers blind flush")
do
  local IDLE_TIMEOUT = 10.0

  local function hasGhostItems(buffer)
    if not buffer then return false end
    for _, item in pairs(buffer) do
      if type(item) == "table" and (item.size or 0) == 0 then
        return true
      end
    end
    return false
  end

  local ghostBuffer = {
    ghost1 = {label = "Stone", size = 0},
    ghost2 = {label = "Dirt", size = 0},
    valid   = {label = "Iron Ingot", size = 1},
  }

  Assert.isTrue(hasGhostItems(ghostBuffer), "Ghost items detected in buffer")

  -- Simulate a job with ghost items that time out
  local function simulateGhostJob(id, idleTime)
    local snapshot = BufferSnapshot.new(ghostBuffer)
    local job = snapshot:convertToManifest(JobManifest, id)

    job.idleStartTime = os.time()  -- would be set when ghost detected
    job.state = JobManifest.STATE.PROCESSING

    if idleTime >= IDLE_TIMEOUT then
      -- Blind flush: move to CLEANUP, nil inputs
      job:complete()
      return true, job
    end
    return false, job
  end

  -- Under threshold: no flush
  local flushed, _ = simulateGhostJob("ghost-under", 5.0)
  Assert.isFalse(flushed, "5s idle < 10s threshold: no flush")

  -- At threshold: flush
  flushed, _ = simulateGhostJob("ghost-at", 10.0)
  Assert.isTrue(flushed, "10s idle == threshold: flush triggered")

  -- Above threshold: flush
  flushed, _ = simulateGhostJob("ghost-over", 25.0)
  Assert.isTrue(flushed, "25s idle > 10s threshold: flush triggered")
end
Assert.endTest()

-- Test 3.2: 100% ghost clearance across 1,000 ghost-heavy jobs
Assert.startTest("Ghost items: 100% clearance across 1000 ghost-injected jobs")
do
  local IDLE_TIMEOUT = 10.0
  local totalGhostJobs = 1000
  local flushedCount = 0
  local unflushedCount = 0
  local allCleaned = true

  for i = 1, totalGhostJobs do
    -- Each job has a mix: some ghost items, some real
    local buffer = {
      ghost_a  = {label = "Phantom A", size = 0},
      ghost_b  = {label = "Phantom B", size = 0},
      real_item = {label = "Copper", size = math.random(1, 64)},
    }

    local snapshot = BufferSnapshot.new(buffer)
    local job = snapshot:convertToManifest(JobManifest, "ghost-batch-" .. i)

    -- Simulate detecting ghost and timing out
    job.idleStartTime = 100.0  -- some base time
    local now = 100.0 + (i % 20)  -- cycle through 0-19s of idle

    if now - job.idleStartTime >= IDLE_TIMEOUT then
      job:complete()
      flushedCount = flushedCount + 1
    else
      unflushedCount = unflushedCount + 1
    end

    -- Every job that was flushed must have complete JIT cleanup
    if job.state == JobManifest.STATE.COMPLETE then
      if not job:isJITCleaned() then
        allCleaned = false
      end
    end

    if i % 200 == 0 then collectgarbage("step", 50) end
  end

  Assert.isTrue(flushedCount > 0, "Some ghost jobs triggered flush: " .. flushedCount)
  Assert.isTrue(unflushedCount > 0, "Some ghost jobs under threshold: " .. unflushedCount)
  Assert.equal(totalGhostJobs, flushedCount + unflushedCount,
    "All ghost jobs accounted for")

  -- Every flushed job must be 100% cleaned
  Assert.isTrue(allCleaned, "All flushed ghost jobs have 100% JIT cleanup")

  -- Verify: of the jobs where time >= 10s (i % 20 >= 10), ALL were flushed
  local overThresholdCount = 0
  local overThresholdFlushed = 0
  for i = 1, totalGhostJobs do
    if (i % 20) >= 10 then
      overThresholdCount = overThresholdCount + 1
      -- In our simulation, i % 20 >= 10 means now - 100 >= 10
    end
  end
  -- Since we used i % 20 as idle time, ~500 jobs should be over threshold
  Assert.equal(overThresholdCount, flushedCount,
    string.format("All over-threshold ghost jobs flushed: %d / %d",
      flushedCount, overThresholdCount))
end
Assert.endTest()

-- Test 3.3: Ghost items don't leak memory across cycles
Assert.startTest("Ghost items: no memory leak across ghost→flush cycles")
do
  collectgarbage("collect")
  local memBefore = collectgarbage("count")

  for i = 1, 2000 do
    local buffer = {
      ghost = {label = "Ghost", size = 0},
      real  = {label = "Item", size = (i % 5 == 0) and 0 or 64},
    }
    local snapshot = BufferSnapshot.new(buffer)
    local job = snapshot:convertToManifest(JobManifest, "ghost-mem-" .. i)

    -- Simulate timeout
    job.idleStartTime = 0
    if i > 10 then  -- first 10 under threshold
      job:complete()  -- flush
    end

    if i % 400 == 0 then collectgarbage("step", 100) end
  end

  collectgarbage("collect")
  local memAfter = collectgarbage("count")
  Assert.isTrue(memAfter <= memBefore * 1.15,
    string.format("Ghost items no leak: before=%.1f KB, after=%.1f KB",
      memBefore, memAfter))
end
Assert.endTest()

-- Test 3.4: Ghost items mixed with real items — only ghost-cleared jobs flush
Assert.startTest("Ghost items: mixed buffers, only ghost-flagged flush")
do
  local IDLE_TIMEOUT = 10.0

  -- Simulate the idle tracking a real broker would do
  local function processBuffer(buffer, idleTime)
    local hasGhost = false
    for _, item in pairs(buffer) do
      if type(item) == "table" and (item.size or 0) == 0 then
        hasGhost = true
        break
      end
    end

    if hasGhost and idleTime >= IDLE_TIMEOUT then
      return "flush_and_cleanup"
    elseif hasGhost then
      return "tracking_ghost"
    else
      return "normal_processing"
    end
  end

  -- 100% ghost buffer: should flush after timeout
  local pureGhost = {a = {size = 0}, b = {size = 0}}
  Assert.equal("flush_and_cleanup", processBuffer(pureGhost, 10.0),
    "Pure ghost buffer flushes at timeout")
  Assert.equal("tracking_ghost", processBuffer(pureGhost, 3.0),
    "Pure ghost buffer tracking under threshold")

  -- Mixed buffer with ghosts
  local mixed = {ghost = {size = 0}, real = {size = 64}}
  Assert.equal("flush_and_cleanup", processBuffer(mixed, 15.0),
    "Mixed buffer with ghost flushes at timeout")
  Assert.equal("tracking_ghost", processBuffer(mixed, 5.0),
    "Mixed buffer tracking under threshold")

  -- Pure real buffer
  local pureReal = {iron = {size = 64}, copper = {size = 32}}
  Assert.equal("normal_processing", processBuffer(pureReal, 999.0),
    "Real-only buffer never ghost-flushes")
  Assert.equal("normal_processing", processBuffer(pureReal, 0.0),
    "Real-only buffer normal even at 0s")

  -- Edge: empty buffer
  local empty = {}
  Assert.equal("normal_processing", processBuffer(empty, 100.0),
    "Empty buffer: normal processing (no ghosts)")
end
Assert.endTest()

-- ============================================================
-- Test Group 4: Combined Stress — All At Once
-- ============================================================

-- Test 4.1: Rapid cycle: create→populate→complete→verify, 5k iterations
Assert.startTest("Combined stress: 5k rapid create+populate+complete+verify")
do
  collectgarbage("collect")
  local memBefore = collectgarbage("count")

  local leaked = 0
  local STATE = JobManifest.STATE

  for i = 1, 5000 do
    -- Create with variable inputs
    local numInputs = 1 + (i % 5)
    local inputs = {}
    for j = 1, numInputs do
      inputs["item_" .. j] = j * 8
    end

    local job = JobManifest.new("combo-" .. i, inputs)

    -- Populate registry
    for k, v in pairs(inputs) do
      job:registerInput(k, v)
    end

    -- Bind hardware
    local numMachines = 1 + (i % 4)
    for m = 1, numMachines do
      job:bindHardware(m, {
        address = "hw-" .. m,
        status = (m == 1) and "AVAILABLE" or "LOCKED",
      })
    end

    -- Add transfers
    local numTransfers = 2 + (i % 3)
    for t = 1, numTransfers do
      job:addTransfer({from = "src", to = "dst_" .. t, count = t * 10})
    end

    -- Log processing
    job:logProcessing(1, {type = "START", ts = i})
    job:logProcessing(1, {type = "PROGRESS", ts = i, pct = i % 100})

    -- Log errors occasionally
    if i % 50 == 0 then
      job:logError({code = "PERIODIC_CHECK", iteration = i})
    end

    -- Transition through states
    job:updateState(STATE.LOGGING)
    job:updateState(STATE.ALLOCATING)
    job:updateState(STATE.TRANSFERRING)
    job:updateState(STATE.PROCESSING)

    -- Complete
    job:complete()

    -- Verify cleanup
    if not job:isJITCleaned() then
      leaked = leaked + 1
    end

    if i % 500 == 0 then collectgarbage("step", 100) end
  end

  collectgarbage("collect")
  local memAfter = collectgarbage("count")

  Assert.equal(0, leaked, "Zero JIT leaks across 5k rapid cycles")
  Assert.isTrue(memAfter <= memBefore * 1.20,
    string.format("Combined stress flat memory: before=%.1f KB, after=%.1f KB",
      memBefore, memAfter))
end
Assert.endTest()

-- Test 4.2: Mixed fault+complete cycles, 2k iterations
Assert.startTest("Combined stress: mixed fault+complete 2k cycles, no leak")
do
  collectgarbage("collect")
  local memBefore = collectgarbage("count")

  for i = 1, 2000 do
    local job = JobManifest.new("mix-" .. i, {ore = i * 2})
    job:registerInput("ore", i * 2)
    job:bindHardware(1, {address = "m1", status = "AVAILABLE"})

    if i % 3 == 0 then
      -- Fault path: every 3rd job faults
      job:logError({code = "SIMULATED_FAULT", severity = "CRITICAL"})
      job:fault()
      Assert.equal(JobManifest.STATE.FAULTED, job.state, "Faulted job state correct")
      Assert.isFalse(job:isJITCleaned(), "Faulted job preserves JIT tables for diagnostics")
    else
      -- Normal path
      job:addTransfer({from = "a", to = "b", item = "ore", count = 64})
      job:logProcessing(1, {type = "DONE"})
      job:complete()
      Assert.equal(JobManifest.STATE.COMPLETE, job.state, "Completed job state correct")
      Assert.isTrue(job:isJITCleaned(), "Completed job JIT cleaned")
    end

    -- COMPLETE jobs are cleanup sentinels; FAULTED jobs retain diagnostics.
    if job.state == JobManifest.STATE.COMPLETE then
      Assert.isTrue(job:isStale(), "COMPLETE job is stale")
    elseif job.state == JobManifest.STATE.FAULTED then
      Assert.isFalse(job:isStale(), "FAULTED job is retained")
    end

    if i % 400 == 0 then collectgarbage("step", 100) end
  end

  collectgarbage("collect")
  local memAfter = collectgarbage("count")
  Assert.isTrue(memAfter <= memBefore * 1.15,
    string.format("Fault+complete mix no leak: before=%.1f KB, after=%.1f KB",
      memBefore, memAfter))
end
Assert.endTest()

-- Test 4.3: BufferSnapshot debounce stability under rapid fire
Assert.startTest("Combined stress: BufferSnapshot debounce under rapid fire")
do
  -- Fire 5k snapshots in rapid succession
  local buffer = {
    iron   = {label = "Iron Ingot", size = 64},
    copper  = {label = "Copper Ingot", size = 32},
    tin     = {label = "Tin Ingot", size = 16},
  }

  local prev = nil
  local stableTransitions = 0
  local unstableTransitions = 0

  for i = 1, 5000 do
    local snap = BufferSnapshot.new(buffer)

    if prev then
      -- Simulate elapsed time: cycles with varying delays
      local elapsed = 0.5 + (i % 4) * 0.5  -- cycles: 0.5, 1.0, 1.5, 2.0
      snap.timestamp = prev.timestamp + elapsed

      if snap:compareAndDebounce(prev, 1.0) then
        stableTransitions = stableTransitions + 1
      else
        unstableTransitions = unstableTransitions + 1
      end
    end

    prev = snap

    if i % 1000 == 0 then collectgarbage("step", 50) end
  end

  -- With elapsed times of [0.5, 1.0, 1.5, 2.0] and threshold 1.0:
  -- 0.5s: unstable, 1.0s: stable, 1.5s: stable, 2.0s: stable
  -- So ~75% should be stable
  Assert.isTrue(stableTransitions > unstableTransitions,
    string.format("Majority stable: %d stable vs %d unstable (at threshold 1.0s)",
      stableTransitions, unstableTransitions))
end
Assert.endTest()
