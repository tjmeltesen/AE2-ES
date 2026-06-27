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
-- Uses production BufferSnapshot and JobManifest modules.
-- Uses shared Assert library and MockEnv.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Environment setup
-- ---------------------------------------------------------------------------
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

local Assert = require("tests.helpers.assertions")

-- ---------------------------------------------------------------------------
-- Package path: ensure src/ and tests/ are on path
-- ---------------------------------------------------------------------------
package.path = "./src/?.lua;./?/init.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path

-- Guard: prevent os.exit() from firing on require when run via test runner
if not _G.RUNNING_STANDALONE then
  _G.RUNNING_STANDALONE = (arg and arg[0]:match("test_state_transitions%.lua$")) and true or false
end

-- ---------------------------------------------------------------------------
-- Production modules — exercise actual production code, not inline stubs
-- ---------------------------------------------------------------------------
local ProdBufferSnapshot = require("buffersnapshot")
local JobManifest = require("jobmanifest")

-- ---------------------------------------------------------------------------
-- Locals
-- ---------------------------------------------------------------------------
local DEBOUNCE_DELAY = 1.5            -- seconds (time between snapshots in tests)
local DEBOUNCE_MS = 1500              -- milliseconds (production compareAndDebounce compares os.epoch() ms vs raw value)

-- ---------------------------------------------------------------------------
-- Mock Component Framework
-- We keep mocks for transposer, GT machines, etc. since these are
-- hardware abstractions that can't run without the OC runtime.
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
-- Helper: control os.time for precise debounce testing
-- Allows creating BufferSnapshot objects at controlled timestamps.
-- ---------------------------------------------------------------------------
local TimeControl = {}
local _realTime = os.time
local _realEpoch = os.epoch

function TimeControl.set(t)
  os.time = function() return t end
  os.epoch = function() return t * 1000 end
end

function TimeControl.reset()
  os.time = _realTime
  os.epoch = _realEpoch
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
-- Helper: count items in an array-like table
-- ---------------------------------------------------------------------------
local function arrayLength(t)
  local n = 0
  if type(t) ~= "table" then return 0 end
  for _ in ipairs(t) do n = n + 1 end
  return n
end

-- ===========================================================================
-- TEST SUITES
-- ===========================================================================

-- Suite 1: BUFFERING → LOGGING
Assert.startTest("1. BUFFERING → LOGGING")
do
  -- 1.1: Empty buffer → sentinel checksum (production generateChecksum)
  -- 1.1: Empty buffer → valid hash (not sentinel, because {} is a table)
  local emptyBuf = mockEmptyBuffer()
  local hash1 = ProdBufferSnapshot.generateChecksum(emptyBuf.items)
  Assert.notNil(hash1, "Empty buffer → hash computed")
  Assert.type("string", hash1, "Empty buffer hash is string")

  -- 1.2: nil buffer → sentinel checksum
  local hashNil = ProdBufferSnapshot.generateChecksum(nil)
  Assert.equal("00000000", hashNil, "nil buffer → sentinel checksum")

  -- 1.2: Stable buffer → non-empty checksum
  local hash2 = ProdBufferSnapshot.generateChecksum(mockStableBuffer(4).items)
  Assert.isTrue(hash2 ~= "", "Stable buffer → non-empty checksum")
  Assert.isTrue(hash2 ~= "00000000", "Stable buffer → non-sentinel checksum")

  -- 1.3: Same content → same checksum
  local hashA = ProdBufferSnapshot.generateChecksum(mockStableBuffer(4).items)
  local hashB = ProdBufferSnapshot.generateChecksum(mockStableBuffer(4).items)
  Assert.equal(hashA, hashB, "Same buffer content → same checksum")

  -- 1.4: Different content → different checksum
  local hashC = ProdBufferSnapshot.generateChecksum(mockChangingBuffer().items)
  Assert.isFalse(hashC == hashA, "Different buffer → different checksum")

  -- 1.5: compareAndDebounce — two snapshots at zero elapsed time → not stable
  local sData = mockStableBuffer(4)
  local snap1 = ProdBufferSnapshot.new(sData.items)
  local snap2 = ProdBufferSnapshot.new(sData.items)
  Assert.equal(snap1.checksum, snap2.checksum, "Same data → same checksum")
  Assert.isFalse(snap2:compareAndDebounce(snap1, DEBOUNCE_MS),
      "Zero elapsed → not stable")

  -- 1.6: compareAndDebounce with nil other → not stable
  Assert.isFalse(snap1:compareAndDebounce(nil, DEBOUNCE_MS),
      "nil other → not stable")

  -- 1.7: Delayed snapshot with same content → stable after threshold
  TimeControl.set(100)
  local sFirst = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  TimeControl.set(100 + DEBOUNCE_DELAY)
  local sSecond = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  Assert.equal(sFirst.checksum, sSecond.checksum,
      "Delayed snapshots → same checksum")
  Assert.isTrue(sSecond:compareAndDebounce(sFirst, DEBOUNCE_MS),
      tostring(DEBOUNCE_MS) .. "s elapsed → stable")

  -- 1.8: Above threshold → also stable
  TimeControl.set(200)
  local s3 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  TimeControl.set(200 + DEBOUNCE_DELAY + 1.0)
  local s4 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  Assert.isTrue(s4:compareAndDebounce(s3, DEBOUNCE_MS),
      "> threshold → stable")
  TimeControl.reset()

  -- 1.9: getStableCount is accessible on production snapshot
  Assert.equal(0, snap1:getStableCount(), "Initial stableCount = 0")

  -- 1.10: convertToManifest creates JobManifest in LOGGING state
  local manifest = snap1:convertToManifest(JobManifest, "test_job_1")
  Assert.notNil(manifest, "Manifest created via convertToManifest")
  Assert.equal("test_job_1", manifest.jobId, "Manifest ID preserved")
  Assert.equal(JobManifest.STATE.LOGGING, manifest.state,
      "convertToManifest → LOGGING state")
  -- verify inputs were registered in production module's internal registry
  local jitTables = manifest:getJITTables()
  local inputCount = 0
  if jitTables and type(jitTables._inputRegistry) == "table" then
    for _ in pairs(jitTables._inputRegistry) do inputCount = inputCount + 1 end
  end
  Assert.isTrue(inputCount > 0, "Manifest has registered inputs (convertToManifest → registerInput)")
end
Assert.endTest()

-- Suite 2: LOGGING → ALLOCATING
Assert.startTest("2. LOGGING → ALLOCATING")
do
  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "job_alloc")
  Assert.equal(JobManifest.STATE.LOGGING, manifest.state, "Starts in LOGGING")

  -- 2.1: Valid manifest has ID
  Assert.notNil(manifest.jobId, "Manifest has ID")

  -- 2.2: Full allocation — all machines available
  local mockMachines = {
    {hwAddr = "mach-001", ifaceAddr = "iface-001", status = "AVAILABLE"},
    {hwAddr = "mach-002", ifaceAddr = "iface-002", status = "AVAILABLE"},
    {hwAddr = "mach-003", ifaceAddr = "iface-003", status = "AVAILABLE"},
    {hwAddr = "mach-004", ifaceAddr = "iface-004", status = "AVAILABLE"},
  }

  local allocatedMachines = {}
  local function allocateMachines(m, machines, out)
    if m.state ~= JobManifest.STATE.LOGGING then return false end
    local allocated = 0
    for _, mach in ipairs(machines) do
      if mach.status == "AVAILABLE" then
        mach.status = "LOCKED"
        table.insert(out, mach)
        allocated = allocated + 1
      end
    end
    if allocated == 0 then return false end
    m:updateState("ALLOCATING")
    return true
  end

  Assert.isTrue(allocateMachines(manifest, mockMachines, allocatedMachines),
      "Full allocation succeeds")
  Assert.equal(JobManifest.STATE.ALLOCATING, manifest.state, "→ ALLOCATING")
  Assert.equal(4, arrayLength(allocatedMachines), "4 machines allocated")

  -- 2.3: No available machines → fail, stay LOGGING
  local snap2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local m2 = snap2:convertToManifest(JobManifest, "job_no_mach")
  local busyOut = {}
  local busy = {
    {hwAddr = "mach-005", status = "PROCESSING"},
    {hwAddr = "mach-006", status = "LOCKED"},
  }
  Assert.isFalse(allocateMachines(m2, busy, busyOut), "No available → fail")
  Assert.equal(JobManifest.STATE.LOGGING, m2.state, "Stays LOGGING")
  Assert.equal(0, arrayLength(busyOut), "0 allocated")

  -- 2.4: Partial allocation — mixed statuses
  local snap3 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local m3 = snap3:convertToManifest(JobManifest, "job_partial")
  local mixedOut = {}
  local mixed = {
    {hwAddr = "mach-007", status = "AVAILABLE"},
    {hwAddr = "mach-008", status = "PROCESSING"},
    {hwAddr = "mach-009", status = "AVAILABLE"},
    {hwAddr = "mach-010", status = "FAULTED"},
  }
  Assert.isTrue(allocateMachines(m3, mixed, mixedOut), "Partial allocation succeeds")
  Assert.equal(JobManifest.STATE.ALLOCATING, m3.state, "→ ALLOCATING")
  Assert.equal(2, arrayLength(mixedOut), "2 of 4 allocated")
end
Assert.endTest()

-- Suite 3: ALLOCATING → TRANSFERRING
Assert.startTest("3. ALLOCATING → TRANSFERRING")
do
  local transposer = Mocks.newTransposer()
  local db = Mocks.newDatabase()
  local iface = Mocks.newMEInterface()
  db:set(1, "minecraft:iron_ingot", 0)

  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "job_transfer")
  manifest:updateState("ALLOCATING")
  manifest.allocatedMachines = {
    {hwAddr = "mach-001", ifaceAddr = "iface-001", status = "LOCKED"},
    {hwAddr = "mach-002", ifaceAddr = "iface-002", status = "LOCKED"},
  }

  -- 3.1: Configure interfaces
  local function configureInterfaces(m, dbRef, ifaceRef)
    if m.state ~= JobManifest.STATE.ALLOCATING then return false end
    for i, _ in ipairs(m.allocatedMachines) do
      ifaceRef:setInterfaceConfiguration(i, dbRef.address or "db-01", 1, 64)
    end
    return true
  end
  Assert.isTrue(configureInterfaces(manifest, db, iface), "Interface config succeeds")

  -- 3.2: Begin transfer → TRANSFERRING
  local function beginTransfer(m)
    if m.state ~= JobManifest.STATE.ALLOCATING then return false end
    m:updateState("TRANSFERRING")
    return true
  end
  Assert.isTrue(beginTransfer(manifest), "Transfer begins")
  Assert.equal(JobManifest.STATE.TRANSFERRING, manifest.state, "→ TRANSFERRING")

  -- 3.3: Perform item transfer
  local function performTransfer(m, t)
    if m.state ~= JobManifest.STATE.TRANSFERRING then return false end
    for i, _ in ipairs(m.allocatedMachines) do
      t:transferItem(3, 3, 64, i, 1)
    end
    m.transferComplete = true
    return true
  end
  Assert.isTrue(performTransfer(manifest, transposer), "Transfer performs")
  Assert.isTrue(manifest.transferComplete, "Marked complete")
  Assert.equal(2, arrayLength(transposer.transfers), "2 transfer records")

  -- 3.4: Empty inventory → transfer returns 0, no crash
  local snap2 = ProdBufferSnapshot.new(mockStableBuffer(1).items)
  local m2 = snap2:convertToManifest(JobManifest, "job_empty")
  m2:updateState("ALLOCATING")
  m2.allocatedMachines = {
    {hwAddr = "mach-003", ifaceAddr = "iface-003", status = "LOCKED"}
  }
  beginTransfer(m2)
  local t2 = Mocks.newTransposer()
  function t2.transferItem(self, src, sink, count, srcSlot, sinkSlot)
    table.insert(self.transfers, {src = src, sink = sink, count = 0})
    return 0
  end
  Assert.isTrue(performTransfer(m2, t2), "Empty transfer does not crash")
  Assert.equal(1, arrayLength(t2.transfers), "Transfer attempt recorded")
  Assert.equal(0, t2.transfers[1].count, "0 items moved")
end
Assert.endTest()

-- Suite 4: TRANSFERRING → PROCESSING
Assert.startTest("4. TRANSFERRING → PROCESSING")
do
  local machines = {
    Mocks.newGTMachine({active = false, workAllowed = true}),
    Mocks.newGTMachine({active = false, workAllowed = true}),
  }
  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "job_process")
  manifest:updateState("TRANSFERRING")
  manifest.transferComplete = true
  manifest.allocatedMachines = {
    {hwAddr = "mach-001", gtMachine = machines[1], status = "LOCKED"},
    {hwAddr = "mach-002", gtMachine = machines[2], status = "LOCKED"},
  }

  -- 4.1: Transfer complete → start processing
  local function startProcessing(m)
    if m.state ~= JobManifest.STATE.TRANSFERRING then return false end
    if not m.transferComplete then return false end
    m:updateState("PROCESSING")
    for _, mach in ipairs(m.allocatedMachines) do
      if mach.gtMachine then mach.gtMachine:setWorkAllowed(true) end
    end
    return true
  end
  Assert.isTrue(startProcessing(manifest), "Processing starts")
  Assert.equal(JobManifest.STATE.PROCESSING, manifest.state, "→ PROCESSING")

  -- 4.2: Incomplete transfer → stay TRANSFERRING
  local snap2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local m2 = snap2:convertToManifest(JobManifest, "job_proc2")
  m2:updateState("TRANSFERRING")
  m2.transferComplete = false
  m2.allocatedMachines = {
    {hwAddr = "mach-003", gtMachine = Mocks.newGTMachine(), status = "LOCKED"}
  }
  Assert.isFalse(startProcessing(m2), "Incomplete → no transition")
  Assert.equal(JobManifest.STATE.TRANSFERRING, m2.state, "Stays TRANSFERRING")

  -- 4.3: Machines enabled after transition
  for _, mach in ipairs(manifest.allocatedMachines) do
    Assert.isTrue(mach.gtMachine:isWorkAllowed(), "Machine work enabled")
  end

  -- 4.4: Progress accumulates
  machines[1].active = true
  machines[2].active = true
  machines[1]:simulateTick(10)
  machines[2]:simulateTick(10)
  Assert.isTrue(machines[1]:getWorkProgress() > 0, "Machine 1 has progress")
  Assert.isTrue(machines[2]:getWorkProgress() > 0, "Machine 2 has progress")
end
Assert.endTest()

-- Suite 5: PROCESSING → CLEANUP
Assert.startTest("5. PROCESSING → CLEANUP")
do
  local machines = {
    Mocks.newGTMachine({active = false, workAllowed = true, workProgress = 85}),
    Mocks.newGTMachine({active = false, workAllowed = true, workProgress = 90}),
  }
  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "job_clean")
  manifest:updateState("PROCESSING")
  manifest.allocatedMachines = {
    {hwAddr = "mach-001", gtMachine = machines[1], status = "PROCESSING"},
    {hwAddr = "mach-002", gtMachine = machines[2], status = "PROCESSING"},
  }

  -- 5.1: Not all done → stay PROCESSING
  local function checkDone(m)
    if m.state ~= JobManifest.STATE.PROCESSING then return false end
    for _, mach in ipairs(m.allocatedMachines) do
      if mach.gtMachine and mach.gtMachine:hasWork() then return false end
    end
    return true
  end
  Assert.isFalse(checkDone(manifest), "Still working → not done")

  -- 5.2: All done → CLEANUP
  machines[1].active = true
  machines[2].active = true
  machines[1]:simulateTick(25)
  machines[2]:simulateTick(20)
  machines[1].active = false; machines[2].active = false
  Assert.isTrue(checkDone(manifest), "All machines done")

  local function toCleanup(m)
    if not checkDone(m) then return false end
    m:updateState("CLEANUP")
    for _, mach in ipairs(m.allocatedMachines) do mach.status = "CLEANING" end
    return true
  end
  Assert.isTrue(toCleanup(manifest), "→ CLEANUP")
  Assert.equal(JobManifest.STATE.CLEANUP, manifest.state, "In CLEANUP")
  for _, mach in ipairs(manifest.allocatedMachines) do
    Assert.equal("CLEANING", mach.status, "Machine status CLEANING")
  end
end
Assert.endTest()

-- Suite 6: CLEANUP → BUFFERING (Full Cycle Reset)
Assert.startTest("6. CLEANUP → BUFFERING (Cycle Reset)")
do
  local transposer = Mocks.newTransposer()
  local machines = {
    Mocks.newGTMachine({active = false, workProgress = 100, workMaxProgress = 100}),
    Mocks.newGTMachine({active = false, workProgress = 100, workMaxProgress = 100}),
  }
  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "job_cycle")
  manifest:updateState("CLEANUP")
  manifest.allocatedMachines = {
    {hwAddr = "mach-001", gtMachine = machines[1], ifaceAddr = "iface-001", status = "CLEANING"},
    {hwAddr = "mach-002", gtMachine = machines[2], ifaceAddr = "iface-002", status = "CLEANING"},
  }

  -- 6.1: Flush outputs
  local function flushOutputs(m, t)
    for _, _ in ipairs(m.allocatedMachines) do
      t:transferItem(3, 2, 64, 1, 1)
    end
    return true
  end
  Assert.isTrue(flushOutputs(manifest, transposer), "Outputs flushed")
  Assert.equal(2, arrayLength(transposer.transfers), "2 output transfers")

  -- 6.2: Release machines
  local function releaseMachines(m)
    for _, mach in ipairs(m.allocatedMachines) do
      mach.status = "AVAILABLE"
      if mach.gtMachine then mach.gtMachine:setWorkAllowed(false) end
    end
    return true
  end
  Assert.isTrue(releaseMachines(manifest), "Machines released")
  for _, mach in ipairs(manifest.allocatedMachines) do
    Assert.equal("AVAILABLE", mach.status, "Machine AVAILABLE")
    Assert.isFalse(mach.gtMachine:isWorkAllowed(), "Work disabled")
  end

  -- 6.3: Complete cleanup via JobManifest:complete()
  manifest:complete()
  Assert.equal(JobManifest.STATE.COMPLETE, manifest.state, "→ COMPLETE")
  Assert.isTrue(manifest:isJITCleaned(), "JIT tables nilled")
  Assert.isTrue(manifest:isStale(), "COMPLETE job is stale (isStale)")

  -- 6.4: Full cycle trace via updateState
  local snap2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local fm = snap2:convertToManifest(JobManifest, "full_cycle")
  fm:updateState("LOGGING"); Assert.equal(JobManifest.STATE.LOGGING, fm.state, "→ LOGGING")
  fm:updateState("ALLOCATING"); Assert.equal(JobManifest.STATE.ALLOCATING, fm.state, "→ ALLOCATING")
  fm:updateState("TRANSFERRING"); Assert.equal(JobManifest.STATE.TRANSFERRING, fm.state, "→ TRANSFERRING")
  fm.transferComplete = true
  fm:updateState("PROCESSING"); Assert.equal(JobManifest.STATE.PROCESSING, fm.state, "→ PROCESSING")
  fm:updateState("CLEANUP"); Assert.equal(JobManifest.STATE.CLEANUP, fm.state, "→ CLEANUP")
  fm:updateState("COMPLETE"); Assert.equal(JobManifest.STATE.COMPLETE, fm.state, "→ COMPLETE")
end
Assert.endTest()

-- Suite 7: Edge — Mid-Transfer Fault
Assert.startTest("7. Edge: Mid-Transfer Fault")
do
  local machines = {
    Mocks.newGTMachine({active = true, workAllowed = true}),
    Mocks.newGTMachine({active = true, workAllowed = true}),
  }
  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "fault_test")
  manifest:updateState("TRANSFERRING")
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
  Assert.isTrue(faulted, "Fault detected")
  Assert.isTrue(fm.gtMachine.faulted, "Machine FAULTED")

  -- 7.2: Skip to CLEANUP on fault
  local function handleFault(m, fmach)
    fmach.status = "FAULTED"
    m.transferComplete = false
    m:updateState("CLEANUP")
    m.faultedMachine = fmach.hwAddr
  end
  handleFault(manifest, fm)
  Assert.equal(JobManifest.STATE.CLEANUP, manifest.state, "Skip to CLEANUP on fault")
  Assert.equal("FAULTED", fm.status, "Marked FAULTED")

  -- 7.3: Non-faulted machine still LOCKED
  Assert.equal("LOCKED", manifest.allocatedMachines[2].status,
      "Non-faulted stays LOCKED")
end
Assert.endTest()

-- Suite 8: Edge — Ghost Items & Idle Timeout
Assert.startTest("8. Edge: Ghost Items & 10s Idle Timeout")
do
  local ghostBuffer = mockGhostItemBuffer()

  -- 8.1: Ghost item detection
  local function hasGhostItems(buffer)
    if not buffer or not buffer.items then return false end
    for _, item in ipairs(buffer.items) do
      if item.size == 0 then return true end
    end
    return false
  end
  Assert.isTrue(hasGhostItems(ghostBuffer), "Ghost items detected")

  -- 8.2: Idle timeout threshold
  local snap = ProdBufferSnapshot.new(ghostBuffer.items)
  local manifest = snap:convertToManifest(JobManifest, "ghost_job")
  manifest:updateState("PROCESSING")
  manifest.idleStartTime = 100.0
  manifest.allocatedMachines = {{hwAddr = "mach-ghost-1", status = "PROCESSING"}}

  local IDLE_TIMEOUT = 10.0
  local function checkTimeout(m, now)
    if not m.idleStartTime then return false end
    return (now - m.idleStartTime) >= IDLE_TIMEOUT
  end

  Assert.isFalse(checkTimeout(manifest, 105.0), "5s idle → NO timeout")
  Assert.isFalse(checkTimeout(manifest, 109.9), "9.9s idle → NO timeout")
  Assert.isTrue(checkTimeout(manifest, 110.0), "10s idle → TIMEOUT")
  Assert.isTrue(checkTimeout(manifest, 120.0), "20s idle → TIMEOUT")

  -- 8.3: Blind flush on timeout
  local function blindFlush(m)
    m:updateState("CLEANUP")
    m.inputs = nil
    return true
  end
  Assert.isTrue(blindFlush(manifest), "Blind flush succeeds")
  Assert.equal(JobManifest.STATE.CLEANUP, manifest.state, "→ CLEANUP")
  Assert.isNil(manifest.inputs, "Inputs cleared")
end
Assert.endTest()

-- Suite 9: Edge — Array Saturation
Assert.startTest("9. Edge: Array Saturation")
do
  local busy = {
    {hwAddr = "mach-01", status = "PROCESSING"},
    {hwAddr = "mach-02", status = "PROCESSING"},
    {hwAddr = "mach-03", status = "PROCESSING"},
    {hwAddr = "mach-04", status = "LOCKED"},
  }
  local function countAvailable(machs)
    local c = 0
    for _, m in ipairs(machs) do
      if m.status == "AVAILABLE" then c = c + 1 end
    end
    return c
  end
  Assert.equal(0, countAvailable(busy), "0 available when saturated")

  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "sat_job")
  Assert.equal(JobManifest.STATE.LOGGING, manifest.state, "Starts LOGGING")

  local allocatedMachines = {}
  local function attemptAlloc(m, machines, out)
    local avail = countAvailable(machines)
    if avail == 0 then return false, "yield" end
    m:updateState("ALLOCATING")
    for _, mach in ipairs(machines) do
      if mach.status == "AVAILABLE" then
        mach.status = "LOCKED"
        table.insert(out, mach)
      end
    end
    return true
  end

  local ok, reason = attemptAlloc(manifest, busy, allocatedMachines)
  Assert.isFalse(ok, "Saturated → fail")
  Assert.equal("yield", reason, "Reason: yield")
  Assert.equal(JobManifest.STATE.LOGGING, manifest.state, "Stays LOGGING")

  -- Machine 2 frees → allocation proceeds
  busy[2].status = "AVAILABLE"
  Assert.equal(1, countAvailable(busy), "1 available")
  Assert.isTrue(attemptAlloc(manifest, busy, allocatedMachines), "Allocation proceeds")
  Assert.equal(JobManifest.STATE.ALLOCATING, manifest.state, "→ ALLOCATING")
end
Assert.endTest()

-- Suite 10: Edge — Premature Buffer Unlock
Assert.startTest("10. Edge: Premature Buffer Unlock")
do
  local function canUnlockBuffer(buffer)
    local items = 0; local fluid = 0
    if buffer.items then
      for _, it in ipairs(buffer.items) do items = items + (it.size or 0) end
    end
    if buffer.fluids then
      for _, fl in ipairs(buffer.fluids) do fluid = fluid + (fl.amount or 0) end
    end
    return items == 0 and fluid == 0
  end

  Assert.isTrue(canUnlockBuffer(mockEmptyBuffer()), "Empty → unlockable")
  Assert.isFalse(canUnlockBuffer(mockStableBuffer(4)), "With items → NOT unlockable")
  Assert.isFalse(canUnlockBuffer(
      {items = {}, fluids = {{name="water", amount=1000}}}),
      "With fluid → NOT unlockable")
  Assert.isTrue(canUnlockBuffer(
      {items = {{name="stone", size=0}}, fluids={}}),
      "Ghost-only → unlockable")

  -- Active manifest gate
  local snap = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  local manifest = snap:convertToManifest(JobManifest, "active")
  manifest:updateState("PROCESSING")

  local function checkGate(buffer, active)
    local bufClear = canUnlockBuffer(buffer)
    local noActive = not active or
        (active.state == JobManifest.STATE.CLEANUP and active.cleanupComplete)
    return bufClear and noActive
  end

  Assert.isFalse(checkGate(mockEmptyBuffer(), manifest),
      "Active manifest → NOT unlock")
  manifest:updateState("CLEANUP"); manifest.cleanupComplete = true
  Assert.isTrue(checkGate(mockEmptyBuffer(), manifest),
      "Cleanup complete + empty → unlock")
end
Assert.endTest()

-- Suite 11: Edge — Maintenance Recovery
Assert.startTest("11. Edge: Maintenance Recovery")
do
  local fm = Mocks.newGTMachine({active = false, faulted = true})
  local polls = 0

  local function poll(machine)
    polls = polls + 1
    return not machine.faulted
  end

  for _ = 1, 3 do
    Assert.isFalse(poll(fm), "Still faulted → not recovered")
  end
  Assert.equal(3, polls, "3 polls while faulted")

  fm.faulted = false; fm.active = true
  Assert.isTrue(poll(fm), "Recovered after repair")

  local function recover(machine, idx)
    if machine.faulted then return false end
    return {hwAddr = "recovered-" .. tostring(idx),
            status = "AVAILABLE", gtMachine = machine}
  end
  local entry = recover(fm, 1)
  Assert.equal("AVAILABLE", entry.status, "Recovered → AVAILABLE")
  Assert.isFalse(entry.gtMachine.faulted, "Not faulted")

  -- Check pool availability
  local pool = {entry}
  local avail = 0
  for _, m in ipairs(pool) do
    if m.status == "AVAILABLE" then avail = avail + 1 end
  end
  Assert.equal(1, avail, "Recovered machine in pool")
end
Assert.endTest()

-- Suite 12: Debounce Timer Precision (production compareAndDebounce)
Assert.startTest("12. Debounce Timer Precision")
do
  -- 12.1: Sub-threshold — gap < threshold
  for _, gap in ipairs({0.0, 0.01, 0.1, 0.5, 0.99, 1.499}) do
    TimeControl.set(500)
    local s1 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
    TimeControl.set(500 + gap)
    local s2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
    Assert.isFalse(s2:compareAndDebounce(s1, DEBOUNCE_MS),
        tostring(gap) .. "s gap (" .. tostring(gap * 1000) .. "ms) < " .. tostring(DEBOUNCE_MS) .. "ms → NO trigger")
  end

  -- 12.2: At/above threshold — gap >= threshold (in ms via DEBOUNCE_MS)
  for _, gap in ipairs({DEBOUNCE_DELAY, DEBOUNCE_DELAY + 0.001,
                        2.0, 5.0, 10.0, 100.0}) do
    TimeControl.set(600)
    local s1 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
    TimeControl.set(600 + gap)
    local s2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
    Assert.isTrue(s2:compareAndDebounce(s1, DEBOUNCE_MS),
        tostring(gap) .. "s gap ≥ " .. tostring(DEBOUNCE_MS) .. "ms → trigger")
  end

  -- 12.3: Boundary precision — just above threshold
  TimeControl.set(700)
  local s1 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  TimeControl.set(700 + DEBOUNCE_DELAY + 0.0001)
  local s2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  Assert.isTrue(s2:compareAndDebounce(s1, DEBOUNCE_MS),
      "Just above threshold → trigger")

  -- 12.4: Negative elapsed → math.abs handles it
  -- sNeg1 created later than sNeg2 but with same content
  TimeControl.set(800)
  local sNeg1 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  TimeControl.set(800 - DEBOUNCE_DELAY - 1.0)
  local sNeg2 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  -- sNeg1 timestamp = 800000ms, sNeg2 timestamp = (800 - 2.5)*1000 = 797500ms
  -- math.abs(800000 - 797500) = 2500ms = 2.5s ≥ 1500ms → true
  Assert.isTrue(sNeg1:compareAndDebounce(sNeg2, DEBOUNCE_MS),
      "Abs handles reversed timestamps → stable when threshold met")

  -- 12.5: Different content → no trigger regardless of timing
  for _, gap in ipairs({0.5, 1.0, 5.0, 999.0}) do
    TimeControl.set(900)
    local s1 = ProdBufferSnapshot.new(mockStableBuffer(4).items)
    TimeControl.set(900 + gap)
    local s2 = ProdBufferSnapshot.new(mockChangingBuffer().items)
    Assert.isFalse(s2:compareAndDebounce(s1, DEBOUNCE_MS),
        "Different buffers at " .. tostring(gap) .. "s → NO trigger")
  end

  TimeControl.reset()

  -- 12.6: Production getStableCount and resetDebounce
  local snapR = ProdBufferSnapshot.new(mockStableBuffer(4).items)
  Assert.equal(0, snapR:getStableCount(), "Fresh snapshot → stableCount = 0")
  snapR:resetDebounce()
  Assert.equal(0, snapR:getStableCount(), "After reset → stableCount = 0")
end
Assert.endTest()

-- ===========================================================================
-- Print summary and guard os.exit for runner compatibility
-- ===========================================================================
local allPassed = Assert.summary()

if _G.RUNNING_STANDALONE then
  os.exit(allPassed and 0 or 1)
end
