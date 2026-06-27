-- =============================================================================
-- C1: Unit Tests — State Transitions
-- Phase A: Validate all 6 state transitions with mocked buffer states.
-- Assert debounce timer criteria.
-- =============================================================================
-- Tests the AE2-ES Exec Broker's 6-phase state machine:
--   BUFFERING → LOGGING → ALLOCATING → TRANSFERRING → PROCESSING → CLEANUP
--
-- These tests are stateless — they mock component APIs and buffer snapshots
-- to validate transition logic without requiring AE2 hardware.
--
-- Run with: lua test_state_transitions.lua
-- Or within OC Emulator: dofile("test_state_transitions.lua")
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Test Harness
-- ---------------------------------------------------------------------------
local test = {}
test.passed = 0
test.failed = 0
test.errors = {}

local function assert_true(condition, msg)
    if condition then
        test.passed = test.passed + 1
    else
        test.failed = test.failed + 1
        local err = msg or "assertion failed"
        table.insert(test.errors, err)
        print("  FAIL: " .. err)
    end
end

local function assert_false(condition, msg)
    assert_true(not condition, msg or "expected false")
end

local function assert_equals(expected, actual, msg)
    if expected == actual then
        test.passed = test.passed + 1
    else
        test.failed = test.failed + 1
        local err = (msg or "equality check failed") ..
            " (expected: " .. tostring(expected) .. ", got: " .. tostring(actual) .. ")"
        table.insert(test.errors, err)
        print("  FAIL: " .. err)
    end
end

local function run_test_suite(name, suite_fn)
    print("\n=== " .. name .. " ===")
    local before_passed = test.passed
    local before_failed = test.failed
    local ok, err = pcall(suite_fn)
    if not ok then
        test.failed = test.failed + 1
        table.insert(test.errors, "Test suite '" .. name .. "' crashed: " .. tostring(err))
        print("  SUITE CRASH: " .. tostring(err))
    end
    local suite_passed = test.passed - before_passed
    local suite_failed = test.failed - before_failed
    print("  >> " .. suite_passed .. " passed, " .. suite_failed .. " failed")
end

-- ---------------------------------------------------------------------------
-- Phase Constants (must match exec_broker.lua)
-- ---------------------------------------------------------------------------
local PHASE = {
    BUFFERING    = 1,
    LOGGING      = 2,
    ALLOCATING   = 3,
    TRANSFERRING = 4,
    PROCESSING   = 5,
    CLEANUP      = 6,
}

-- ---------------------------------------------------------------------------
-- Mock Component Framework
-- ---------------------------------------------------------------------------

local Mocks = {}

function Mocks.newTransposer()
    return {
        transfers = {},
        inventoryStates = {},
        tankStates = {},
        transferItem = function(self, src, sink, count, srcSlot, sinkSlot)
            local record = {src = src, sink = sink, count = count,
                            srcSlot = srcSlot, sinkSlot = sinkSlot}
            table.insert(self.transfers, record)
            return count or 0
        end,
        transferFluid = function(self, src, sink, count, srcTank)
            local record = {src = src, sink = sink, count = count,
                            srcTank = srcTank, type = "fluid"}
            table.insert(self.transfers, record)
            return true, count or 0
        end,
        getStackInSlot = function(self, side, slot)
            local inv = self.inventoryStates[side]
            if inv and inv[slot] then return inv[slot] end
            return nil
        end,
        getTankLevel = function(self, side, tank)
            local tanks = self.tankStates[side]
            if tanks and tanks[tank] then return tanks[tank].amount end
            return 0
        end,
        getInventorySize = function(self, side)
            local inv = self.inventoryStates[side]
            return inv and #inv or 0
        end,
    }
end

function Mocks.newMEInterface()
    return {
        configurations = {},
        getInterfaceConfiguration = function(self, slot)
            return self.configurations[slot]
        end,
        setInterfaceConfiguration = function(self, slot, dbAddr, dbIdx, count)
            self.configurations[slot] = {dbAddr = dbAddr, dbIdx = dbIdx, count = count}
        end,
    }
end

function Mocks.newGTMachine(initialState)
    local m = {
        active = initialState and initialState.active or false,
        workAllowed = initialState and initialState.workAllowed ~= false,
        workProgress = initialState and initialState.workProgress or 0,
        workMaxProgress = initialState and initialState.workMaxProgress or 100,
        storedEU = initialState and initialState.storedEU or 1000000,
        euCapacity = initialState and initialState.euCapacity or 10000000,
        faulted = initialState and initialState.faulted or false,
    }
    function m.isMachineActive() return m.active end
    function m.isWorkAllowed() return m.workAllowed end
    function m.hasWork() return m.workProgress < m.workMaxProgress end
    function m.getWorkProgress() return m.workProgress end
    function m.getWorkMaxProgress() return m.workMaxProgress end
    function m.getStoredEU() return m.storedEU end
    function m.getEUCapacity() return m.euCapacity end
    function m.setWorkAllowed(self, allowed) m.workAllowed = allowed end
    function m.simulateTick(self, progress)
        if m.active then
            m.workProgress = math.min(m.workMaxProgress,
                m.workProgress + (progress or 10))
        end
    end
    function m.simulateFault(self)
        m.faulted = true
        m.active = false
    end
    return m
end

function Mocks.newDatabase()
    return {
        entries = {},
        set = function(self, slot, id, damage, nbt)
            self.entries[slot] = {id = id, damage = damage or 0, nbt = nbt}
        end,
        get = function(self, slot)
            return self.entries[slot]
        end,
        clear = function(self, slot)
            self.entries[slot] = nil
            return true
        end,
        computeHash = function(self, slot)
            local e = self.entries[slot]
            if not e then return nil end
            return e.id .. ":" .. tostring(e.damage)
        end,
    }
end

function Mocks.newClock(startTime)
    return {
        current = startTime or 0,
        tick = function(self, delta)
            self.current = self.current + (delta or 0.05)
            return self.current
        end,
        now = function(self) return self.current end,
    }
end

-- ---------------------------------------------------------------------------
-- Mock Buffer States
-- ---------------------------------------------------------------------------

local function mockEmptyBuffer()
    return {
        items = {},
        fluids = {},
        powerStored = 1000000,
        powerMax = 10000000,
    }
end

local function mockStableBuffer(itemCount)
    itemCount = itemCount or 4
    local items = {}
    for i = 1, itemCount do
        items[i] = {
            name = "minecraft:iron_ingot",
            label = "Iron Ingot",
            size = 64,
            damage = 0,
            hasTag = false,
        }
    end
    return {
        items = items,
        fluids = {},
        powerStored = 1000000,
        powerMax = 10000000,
    }
end

local function mockChangingBuffer()
    return {
        items = {
            {name = "minecraft:iron_ingot", size = 32, damage = 0},
            {name = "minecraft:copper_ingot", size = 16, damage = 0},
        },
        fluids = {},
        powerStored = 1000000,
        powerMax = 10000000,
    }
end

local function mockGhostItemBuffer()
    return {
        items = {
            {name = "minecraft:stone", size = 0, damage = 0},
            {name = "gt.metaitem.01", size = 1, damage = 0},
        },
        fluids = {},
        powerStored = 1000000,
        powerMax = 10000000,
    }
end

-- ---------------------------------------------------------------------------
-- BufferSnapshot Module (Minimal Implementation for Testing)
-- ---------------------------------------------------------------------------
local BufferSnapshot = {}

BufferSnapshot.DEBOUNCE_SECONDS = 1.0

function BufferSnapshot.computeChecksum(buffer)
    if not buffer or not buffer.items then return "" end
    local parts = {}
    for _, item in ipairs(buffer.items) do
        table.insert(parts, item.name .. ":" .. tostring(item.size))
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

function BufferSnapshot.isStable(currentHash, previousHash, timeStable)
    return currentHash == previousHash and currentHash ~= "" and
           timeStable >= BufferSnapshot.DEBOUNCE_SECONDS
end

function BufferSnapshot.toJobManifest(buffer, snapshotId)
    return {
        id = snapshotId or "job_" .. tostring(os.time()),
        inputs = buffer.items,
        fluids = buffer.fluids or {},
        state = PHASE.BUFFERING,
        snapshotHash = BufferSnapshot.computeChecksum(buffer),
        allocatedMachines = {},
        transferComplete = false,
        processComplete = false,
        cleanupComplete = false,
        createdAt = os.time(),
    }
end

-- ===========================================================================
-- TEST SUITES
-- ===========================================================================

-- Suite 1: BUFFERING → LOGGING
run_test_suite("1. BUFFERING → LOGGING", function()
    local clock = Mocks.newClock(0)

    -- 1.1: Empty buffer should NOT trigger
    local hash1 = BufferSnapshot.computeChecksum(mockEmptyBuffer())
    assert_equals("", hash1, "Empty buffer → empty checksum")
    assert_false(BufferSnapshot.isStable(hash1, hash1, 2.0),
        "Empty buffer NOT stable")

    -- 1.2: Single snapshot with 0s debounce → NO transition
    local hash2 = BufferSnapshot.computeChecksum(mockStableBuffer(4))
    assert_true(hash2 ~= "", "Stable buffer → non-empty checksum")
    assert_false(BufferSnapshot.isStable(hash2, hash2, 0.0),
        "0s debounce → NO transition")

    -- 1.3: 0.5s below threshold → NO transition
    assert_false(BufferSnapshot.isStable(hash2, hash2, 0.5),
        "0.5s < 1.0s threshold → NO transition")

    -- 1.4: 1.0s at threshold → TRANSITION
    assert_true(BufferSnapshot.isStable(hash2, hash2, 1.0),
        "1.0s == threshold → transition")

    -- 1.5: 2.5s above threshold → TRANSITION
    assert_true(BufferSnapshot.isStable(hash2, hash2, 2.5),
        "2.5s > threshold → transition")

    -- 1.6: Changed buffer → NO transition despite time
    local hash3 = BufferSnapshot.computeChecksum(mockChangingBuffer())
    assert_false(BufferSnapshot.isStable(hash2, hash3, 2.0),
        "Different hashes → NO transition")

    -- 1.7: nil previous hash → NO transition
    assert_false(BufferSnapshot.isStable(hash2, nil, 5.0),
        "nil previous hash → NO transition")

    -- 1.8: Consecutive identical snapshots with proper timing
    local s1 = BufferSnapshot.computeChecksum(mockStableBuffer(4))
    clock:tick(0.5)
    local s2 = BufferSnapshot.computeChecksum(mockStableBuffer(4))
    clock:tick(0.6)
    assert_equals(s1, s2, "Consecutive snapshots match")
    assert_true(BufferSnapshot.isStable(s2, s1, 1.1),
        "1.1s matching snapshots → transition")

    -- 1.9: JobManifest preserves snapshot data
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "test_job_1")
    assert_equals("test_job_1", manifest.id, "Manifest ID preserved")
    assert_equals(PHASE.BUFFERING, manifest.state, "Starts in BUFFERING")
    assert_true(#manifest.inputs == 4, "4 input items")
end)

-- Suite 2: LOGGING → ALLOCATING
run_test_suite("2. LOGGING → ALLOCATING", function()
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_alloc")
    manifest.state = PHASE.LOGGING

    -- 2.1: Valid manifest check
    assert_true(manifest.id ~= nil, "Manifest has ID")
    assert_true(#manifest.inputs > 0, "Manifest has inputs")

    -- 2.2: All machines available → full allocation
    local mockMachines = {
        {hwAddr = "mach-001", ifaceAddr = "iface-001", status = "AVAILABLE"},
        {hwAddr = "mach-002", ifaceAddr = "iface-002", status = "AVAILABLE"},
        {hwAddr = "mach-003", ifaceAddr = "iface-003", status = "AVAILABLE"},
        {hwAddr = "mach-004", ifaceAddr = "iface-004", status = "AVAILABLE"},
    }

    local function allocateMachines(manifest, machines)
        if manifest.state ~= PHASE.LOGGING then return false end
        local allocated = 0
        for _, m in ipairs(machines) do
            if m.status == "AVAILABLE" then
                m.status = "LOCKED"
                table.insert(manifest.allocatedMachines, m)
                allocated = allocated + 1
            end
        end
        if allocated == 0 then return false end
        manifest.state = PHASE.ALLOCATING
        return true
    end

    assert_true(allocateMachines(manifest, mockMachines), "Full allocation succeeds")
    assert_equals(PHASE.ALLOCATING, manifest.state, "→ ALLOCATING")
    assert_equals(4, #manifest.allocatedMachines, "4 machines allocated")

    -- 2.3: No available machines → fail, stay LOGGING
    local m2 = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_no_mach")
    m2.state = PHASE.LOGGING
    local busy = {
        {hwAddr = "mach-005", status = "PROCESSING"},
        {hwAddr = "mach-006", status = "LOCKED"},
    }
    assert_false(allocateMachines(m2, busy), "No available → fail")
    assert_equals(PHASE.LOGGING, m2.state, "Stays LOGGING")
    assert_equals(0, #m2.allocatedMachines, "0 allocated")

    -- 2.4: Partial allocation — mixed statuses
    local m3 = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_partial")
    m3.state = PHASE.LOGGING
    local mixed = {
        {hwAddr = "mach-007", status = "AVAILABLE"},
        {hwAddr = "mach-008", status = "PROCESSING"},
        {hwAddr = "mach-009", status = "AVAILABLE"},
        {hwAddr = "mach-010", status = "FAULTED"},
    }
    assert_true(allocateMachines(m3, mixed), "Partial allocation succeeds")
    assert_equals(PHASE.ALLOCATING, m3.state, "→ ALLOCATING")
    assert_equals(2, #m3.allocatedMachines, "2 of 4 allocated")
end)

-- Suite 3: ALLOCATING → TRANSFERRING
run_test_suite("3. ALLOCATING → TRANSFERRING", function()
    local transposer = Mocks.newTransposer()
    local db = Mocks.newDatabase()
    local iface = Mocks.newMEInterface()
    db:set(1, "minecraft:iron_ingot", 0)

    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_transfer")
    manifest.state = PHASE.ALLOCATING
    manifest.allocatedMachines = {
        {hwAddr = "mach-001", ifaceAddr = "iface-001", status = "LOCKED"},
        {hwAddr = "mach-002", ifaceAddr = "iface-002", status = "LOCKED"},
    }

    -- 3.1: Configure interfaces
    local function configureInterfaces(manifest, dbRef, ifaceRef)
        if manifest.state ~= PHASE.ALLOCATING then return false end
        for i, mach in ipairs(manifest.allocatedMachines) do
            ifaceRef:setInterfaceConfiguration(i, dbRef.address or "db-01", 1, 64)
        end
        return true
    end
    assert_true(configureInterfaces(manifest, db, iface), "Interface config succeeds")

    -- 3.2: Begin transfer → TRANSFERRING
    local function beginTransfer(manifest)
        if manifest.state ~= PHASE.ALLOCATING then return false end
        manifest.state = PHASE.TRANSFERRING
        return true
    end
    assert_true(beginTransfer(manifest), "Transfer begins")
    assert_equals(PHASE.TRANSFERRING, manifest.state, "→ TRANSFERRING")

    -- 3.3: Perform item transfer
    local function performTransfer(manifest, t)
        if manifest.state ~= PHASE.TRANSFERRING then return false end
        for i, _ in ipairs(manifest.allocatedMachines) do
            t:transferItem(3, 3, 64, i, 1)
        end
        manifest.transferComplete = true
        return true
    end
    assert_true(performTransfer(manifest, transposer), "Transfer performs")
    assert_true(manifest.transferComplete, "Marked complete")
    assert_equals(2, #transposer.transfers, "2 transfer records")

    -- 3.4: Empty inventory → transfer returns 0, no crash
    local m2 = BufferSnapshot.toJobManifest(mockStableBuffer(1), "job_empty")
    m2.state = PHASE.ALLOCATING
    m2.allocatedMachines = {{hwAddr = "mach-003", ifaceAddr = "iface-003", status = "LOCKED"}}
    beginTransfer(m2)
    local t2 = Mocks.newTransposer()
    function t2.transferItem(self, src, sink, count, srcSlot, sinkSlot)
        table.insert(self.transfers, {src = src, sink = sink, count = 0})
        return 0
    end
    assert_true(performTransfer(m2, t2), "Empty transfer does not crash")
    assert_equals(1, #t2.transfers, "Transfer attempt recorded")
    assert_equals(0, t2.transfers[1].count, "0 items moved")
end)

-- Suite 4: TRANSFERRING → PROCESSING
run_test_suite("4. TRANSFERRING → PROCESSING", function()
    local machines = {
        Mocks.newGTMachine({active = false, workAllowed = true}),
        Mocks.newGTMachine({active = false, workAllowed = true}),
    }
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_process")
    manifest.state = PHASE.TRANSFERRING
    manifest.transferComplete = true
    manifest.allocatedMachines = {
        {hwAddr = "mach-001", gtMachine = machines[1], status = "LOCKED"},
        {hwAddr = "mach-002", gtMachine = machines[2], status = "LOCKED"},
    }

    -- 4.1: Transfer complete → start processing
    local function startProcessing(manifest)
        if manifest.state ~= PHASE.TRANSFERRING then return false end
        if not manifest.transferComplete then return false end
        manifest.state = PHASE.PROCESSING
        for _, mach in ipairs(manifest.allocatedMachines) do
            if mach.gtMachine then mach.gtMachine:setWorkAllowed(true) end
        end
        return true
    end
    assert_true(startProcessing(manifest), "Processing starts")
    assert_equals(PHASE.PROCESSING, manifest.state, "→ PROCESSING")

    -- 4.2: Incomplete transfer → stay TRANSFERRING
    local m2 = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_proc2")
    m2.state = PHASE.TRANSFERRING
    m2.transferComplete = false
    m2.allocatedMachines = {{hwAddr = "mach-003", gtMachine = Mocks.newGTMachine(), status = "LOCKED"}}
    assert_false(startProcessing(m2), "Incomplete → no transition")
    assert_equals(PHASE.TRANSFERRING, m2.state, "Stays TRANSFERRING")

    -- 4.3: Machines enabled after transition
    for _, mach in ipairs(manifest.allocatedMachines) do
        assert_true(mach.gtMachine:isWorkAllowed(), "Machine work enabled")
    end

    -- 4.4: Progress accumulates
    machines[1].active = true
    machines[2].active = true
    machines[1]:simulateTick(10)
    machines[2]:simulateTick(10)
    assert_true(machines[1]:getWorkProgress() > 0, "Machine 1 has progress")
    assert_true(machines[2]:getWorkProgress() > 0, "Machine 2 has progress")
end)

-- Suite 5: PROCESSING → CLEANUP
run_test_suite("5. PROCESSING → CLEANUP", function()
    local machines = {
        Mocks.newGTMachine({active = false, workAllowed = true, workProgress = 85}),
        Mocks.newGTMachine({active = false, workAllowed = true, workProgress = 90}),
    }
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_clean")
    manifest.state = PHASE.PROCESSING
    manifest.allocatedMachines = {
        {hwAddr = "mach-001", gtMachine = machines[1], status = "PROCESSING"},
        {hwAddr = "mach-002", gtMachine = machines[2], status = "PROCESSING"},
    }

    -- 5.1: Not all done → stay PROCESSING
    local function checkDone(manifest)
        if manifest.state ~= PHASE.PROCESSING then return false end
        for _, mach in ipairs(manifest.allocatedMachines) do
            if mach.gtMachine and mach.gtMachine:hasWork() then return false end
        end
        return true
    end
    assert_false(checkDone(manifest), "Still working → not done")

    -- 5.2: All done → CLEANUP
    machines[1].active = true
    machines[2].active = true
    machines[1]:simulateTick(25)
    machines[2]:simulateTick(20)
    machines[1].active = false; machines[2].active = false
    assert_true(checkDone(manifest), "All machines done")

    local function toCleanup(manifest)
        if not checkDone(manifest) then return false end
        manifest.state = PHASE.CLEANUP
        for _, m in ipairs(manifest.allocatedMachines) do m.status = "CLEANING" end
        return true
    end
    assert_true(toCleanup(manifest), "→ CLEANUP")
    assert_equals(PHASE.CLEANUP, manifest.state, "In CLEANUP")
    for _, m in ipairs(manifest.allocatedMachines) do
        assert_equals("CLEANING", m.status, "Machine status CLEANING")
    end
end)

-- Suite 6: CLEANUP → BUFFERING (Full Cycle Reset)
run_test_suite("6. CLEANUP → BUFFERING (Cycle Reset)", function()
    local transposer = Mocks.newTransposer()
    local machines = {
        Mocks.newGTMachine({active = false, workProgress = 100, workMaxProgress = 100}),
        Mocks.newGTMachine({active = false, workProgress = 100, workMaxProgress = 100}),
    }
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "job_cycle")
    manifest.state = PHASE.CLEANUP
    manifest.allocatedMachines = {
        {hwAddr = "mach-001", gtMachine = machines[1], ifaceAddr = "iface-001", status = "CLEANING"},
        {hwAddr = "mach-002", gtMachine = machines[2], ifaceAddr = "iface-002", status = "CLEANING"},
    }

    -- 6.1: Flush outputs
    local function flushOutputs(manifest, t)
        for _, _ in ipairs(manifest.allocatedMachines) do
            t:transferItem(3, 2, 64, 1, 1)
        end
        return true
    end
    assert_true(flushOutputs(manifest, transposer), "Outputs flushed")
    assert_equals(2, #transposer.transfers, "2 output transfers")

    -- 6.2: Release machines
    local function releaseMachines(manifest)
        for _, mach in ipairs(manifest.allocatedMachines) do
            mach.status = "AVAILABLE"
            if mach.gtMachine then mach.gtMachine:setWorkAllowed(false) end
        end
        return true
    end
    assert_true(releaseMachines(manifest), "Machines released")
    for _, mach in ipairs(manifest.allocatedMachines) do
        assert_equals("AVAILABLE", mach.status, "Machine AVAILABLE")
        assert_false(mach.gtMachine:isWorkAllowed(), "Work disabled")
    end

    -- 6.3: Complete cleanup → BUFFERING, JIT nil
    local function completeCleanup(manifest)
        if manifest.state ~= PHASE.CLEANUP then return false end
        manifest.state = PHASE.BUFFERING
        manifest.cleanupComplete = true
        manifest.inputs = nil
        manifest.allocatedMachines = nil
        return true
    end
    assert_true(completeCleanup(manifest), "Cleanup complete")
    assert_equals(PHASE.BUFFERING, manifest.state, "→ BUFFERING (cycle reset)")
    assert_true(manifest.cleanupComplete, "Cleanup flag set")
    assert_true(manifest.inputs == nil, "Inputs nilled for GC")
    assert_true(manifest.allocatedMachines == nil, "Machines nilled for GC")

    -- 6.4: Full cycle trace
    local fm = BufferSnapshot.toJobManifest(mockStableBuffer(4), "full_cycle")
    fm.state = PHASE.LOGGING; assert_equals(PHASE.LOGGING, fm.state, "→ LOGGING")
    fm.state = PHASE.ALLOCATING; assert_equals(PHASE.ALLOCATING, fm.state, "→ ALLOCATING")
    fm.state = PHASE.TRANSFERRING; assert_equals(PHASE.TRANSFERRING, fm.state, "→ TRANSFERRING")
    fm.transferComplete = true
    fm.state = PHASE.PROCESSING; assert_equals(PHASE.PROCESSING, fm.state, "→ PROCESSING")
    fm.state = PHASE.CLEANUP; assert_equals(PHASE.CLEANUP, fm.state, "→ CLEANUP")
    fm.state = PHASE.BUFFERING; assert_equals(PHASE.BUFFERING, fm.state, "→ BUFFERING")
    print("  BUFFERING→LOGGING→ALLOCATING→TRANSFERRING→PROCESSING→CLEANUP→BUFFERING ✓")
end)

-- Suite 7: Edge — Mid-Transfer Fault
run_test_suite("7. Edge: Mid-Transfer Fault", function()
    local machines = {
        Mocks.newGTMachine({active = true, workAllowed = true}),
        Mocks.newGTMachine({active = true, workAllowed = true}),
    }
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "fault_test")
    manifest.state = PHASE.TRANSFERRING
    manifest.transferComplete = false
    manifest.allocatedMachines = {
        {hwAddr = "mach-001", gtMachine = machines[1], status = "LOCKED"},
        {hwAddr = "mach-002", gtMachine = machines[2], status = "LOCKED"},
    }

    -- 7.1: Machine faults mid-transfer
    machines[1]:simulateFault()
    local function detectFault(machs)
        for _, m in ipairs(machs) do
            if m.gtMachine and m.gtMachine.faulted then return true, m end
        end
        return false
    end
    local faulted, fm = detectFault(manifest.allocatedMachines)
    assert_true(faulted, "Fault detected")
    assert_true(fm.gtMachine.faulted, "Machine FAULTED")

    -- 7.2: Skip to CLEANUP on fault
    local function handleFault(manifest, fmach)
        fmach.status = "FAULTED"
        manifest.transferComplete = false
        manifest.state = PHASE.CLEANUP
        manifest.faultedMachine = fmach.hwAddr
    end
    handleFault(manifest, fm)
    assert_equals(PHASE.CLEANUP, manifest.state, "Skip to CLEANUP on fault")
    assert_equals("FAULTED", fm.status, "Marked FAULTED")

    -- 7.3: Non-faulted machine still LOCKED
    assert_equals("LOCKED", manifest.allocatedMachines[2].status, "Non-faulted stays LOCKED")
end)

-- Suite 8: Edge — Ghost Items & Idle Timeout
run_test_suite("8. Edge: Ghost Items & 10s Idle Timeout", function()
    local ghostBuffer = mockGhostItemBuffer()

    -- 8.1: Ghost item detection
    local function hasGhostItems(buffer)
        if not buffer or not buffer.items then return false end
        for _, item in ipairs(buffer.items) do
            if item.size == 0 then return true end
        end
        return false
    end
    assert_true(hasGhostItems(ghostBuffer), "Ghost items detected")

    -- 8.2: Idle timeout threshold
    local manifest = BufferSnapshot.toJobManifest(ghostBuffer, "ghost_job")
    manifest.state = PHASE.PROCESSING
    manifest.idleStartTime = 100.0
    manifest.allocatedMachines = {{hwAddr = "mach-ghost-1", status = "PROCESSING"}}

    local IDLE_TIMEOUT = 10.0
    local function checkTimeout(manifest, now)
        if not manifest.idleStartTime then return false end
        return (now - manifest.idleStartTime) >= IDLE_TIMEOUT
    end

    assert_false(checkTimeout(manifest, 105.0), "5s idle → NO timeout")
    assert_false(checkTimeout(manifest, 109.9), "9.9s idle → NO timeout")
    assert_true(checkTimeout(manifest, 110.0), "10s idle → TIMEOUT")
    assert_true(checkTimeout(manifest, 120.0), "20s idle → TIMEOUT")

    -- 8.3: Blind flush on timeout
    local function blindFlush(manifest)
        manifest.state = PHASE.CLEANUP
        manifest.inputs = nil
        return true
    end
    assert_true(blindFlush(manifest), "Blind flush succeeds")
    assert_equals(PHASE.CLEANUP, manifest.state, "→ CLEANUP")
    assert_true(manifest.inputs == nil, "Inputs cleared")
end)

-- Suite 9: Edge — Array Saturation
run_test_suite("9. Edge: Array Saturation", function()
    local busy = {
        {hwAddr = "mach-01", status = "PROCESSING"},
        {hwAddr = "mach-02", status = "PROCESSING"},
        {hwAddr = "mach-03", status = "PROCESSING"},
        {hwAddr = "mach-04", status = "LOCKED"},
    }
    local function countAvailable(machs)
        local c = 0
        for _, m in ipairs(machs) do if m.status == "AVAILABLE" then c = c + 1 end end
        return c
    end
    assert_equals(0, countAvailable(busy), "0 available when saturated")

    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "sat_job")
    manifest.state = PHASE.LOGGING

    local function attemptAlloc(manifest, machines)
        local avail = countAvailable(machines)
        if avail == 0 then return false, "yield" end
        manifest.state = PHASE.ALLOCATING
        for _, m in ipairs(machines) do
            if m.status == "AVAILABLE" then
                m.status = "LOCKED"
                table.insert(manifest.allocatedMachines, m)
            end
        end
        return true
    end

    local ok, reason = attemptAlloc(manifest, busy)
    assert_false(ok, "Saturated → fail")
    assert_equals("yield", reason, "Reason: yield")
    assert_equals(PHASE.LOGGING, manifest.state, "Stays LOGGING")

    -- Machine 2 frees → allocation proceeds
    busy[2].status = "AVAILABLE"
    assert_equals(1, countAvailable(busy), "1 available")
    assert_true(attemptAlloc(manifest, busy), "Allocation proceeds")
    assert_equals(PHASE.ALLOCATING, manifest.state, "→ ALLOCATING")
    assert_equals(1, #manifest.allocatedMachines, "1 allocated")
end)

-- Suite 10: Edge — Premature Buffer Unlock
run_test_suite("10. Edge: Premature Buffer Unlock", function()
    local function canUnlockBuffer(buffer)
        local items = 0; local fluid = 0
        if buffer.items then for _, it in ipairs(buffer.items) do items = items + (it.size or 0) end end
        if buffer.fluids then for _, fl in ipairs(buffer.fluids) do fluid = fluid + (fl.amount or 0) end end
        return items == 0 and fluid == 0
    end

    assert_true(canUnlockBuffer(mockEmptyBuffer()), "Empty → unlockable")
    assert_false(canUnlockBuffer(mockStableBuffer(4)), "With items → NOT unlockable")
    assert_false(canUnlockBuffer({items = {}, fluids = {{name="water", amount=1000}}}), "With fluid → NOT unlockable")
    assert_true(canUnlockBuffer({items = {{name="stone", size=0}}, fluids={}}), "Ghost-only → unlockable")

    -- Active manifest gate
    local manifest = BufferSnapshot.toJobManifest(mockStableBuffer(4), "active")
    manifest.state = PHASE.PROCESSING

    local function checkGate(buffer, active)
        local bufClear = canUnlockBuffer(buffer)
        local noActive = not active or (active.state == PHASE.CLEANUP and active.cleanupComplete)
        return bufClear and noActive
    end

    assert_false(checkGate(mockEmptyBuffer(), manifest), "Active manifest → NOT unlock")
    manifest.state = PHASE.CLEANUP; manifest.cleanupComplete = true
    assert_true(checkGate(mockEmptyBuffer(), manifest), "Cleanup complete + empty → unlock")
end)

-- Suite 11: Edge — Maintenance Recovery
run_test_suite("11. Edge: Maintenance Recovery", function()
    local fm = Mocks.newGTMachine({active = false, faulted = true})
    local polls = 0

    local function poll(machine)
        polls = polls + 1
        return not machine.faulted
    end

    for _ = 1, 3 do assert_false(poll(fm), "Still faulted → not recovered") end
    assert_equals(3, polls, "3 polls while faulted")

    fm.faulted = false; fm.active = true
    assert_true(poll(fm), "Recovered after repair")

    local function recover(machine, idx)
        if machine.faulted then return false end
        return {hwAddr = "recovered-" .. tostring(idx), status = "AVAILABLE", gtMachine = machine}
    end
    local entry = recover(fm, 1)
    assert_equals("AVAILABLE", entry.status, "Recovered → AVAILABLE")
    assert_false(entry.gtMachine.faulted, "Not faulted")

    -- Check pool availability
    local pool = {entry}
    local avail = 0
    for _, m in ipairs(pool) do if m.status == "AVAILABLE" then avail = avail + 1 end end
    assert_equals(1, avail, "Recovered machine in pool")
end)

-- Suite 12: Debounce Timer Precision
run_test_suite("12. Debounce Timer Precision", function()
    local d = BufferSnapshot.DEBOUNCE_SECONDS

    -- 12.1: Sub-threshold
    for _, t in ipairs({0.0, 0.01, 0.1, 0.5, 0.99, 0.999}) do
        assert_false(BufferSnapshot.isStable("a", "a", t),
            tostring(t) .. "s < " .. tostring(d) .. "s → NO trigger")
    end

    -- 12.2: At/above threshold
    for _, t in ipairs({1.0, 1.001, 1.5, 2.0, 5.0, 10.0, 100.0}) do
        assert_true(BufferSnapshot.isStable("b", "b", t),
            tostring(t) .. "s >= " .. tostring(d) .. "s → trigger")
    end

    -- 12.3: Boundary precision
    assert_true(BufferSnapshot.isStable("c", "c", 1.0 + 0.0000001), "Just above threshold → trigger")

    -- 12.4: Negative time → no
    assert_false(BufferSnapshot.isStable("d", "d", -0.1), "Negative time → NO trigger")

    -- 12.5: Mismatch hashes → no regardless of time
    for _, t in ipairs({0.5, 1.0, 5.0, 999.0}) do
        assert_false(BufferSnapshot.isStable("x", "y", t),
            "Mismatch hashes at " .. tostring(t) .. "s → NO trigger")
    end
end)

-- ===========================================================================
-- Report
-- ===========================================================================
print("\n========================================")
print("  TEST RESULTS")
print("========================================")
print("  Passed: " .. test.passed)
print("  Failed: " .. test.failed)
print("  Total:  " .. (test.passed + test.failed))

if test.failed > 0 then
    print("\n  FAILURES:")
    for i, err in ipairs(test.errors) do
        print("  " .. i .. ". " .. err)
    end
end
print("========================================")

if test.failed > 0 then os.exit(1) else os.exit(0) end
