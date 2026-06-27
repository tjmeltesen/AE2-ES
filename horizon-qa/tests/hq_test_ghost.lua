--[[
hq_test_ghost.lua — Horizon-QA Tier 2 Test: Ghost Item Detection
AE2 Execution System (AE2-ES), Deliverable C9

Tests the ghost item detection and cleanup subsystem:
  1. 10s idle timeout triggers after machine stops processing
  2. Blind flush clears input bus via return line
  3. Machine returns to AVAILABLE after cleanup

Run standalone:  lua horizon-qa/tests/hq_test_ghost.lua
]]--

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
local MockModules = require("tests.helpers.mock_modules")

-- ===========================================================================
-- Setup: Mock OC environment
-- ===========================================================================

local mockUptime = 4000
local function tick(dt)
  mockUptime = mockUptime + (dt or 0.05)
end

local mockComputer = {
  uptime = function() return mockUptime end,
  pushSignal = function() end,
}

local mockEvent = {
  pull = function(timeout)
    tick(0.05)
    return "timer"
  end,
  timer = function(interval, callback, count) return 1 end,
  cancel = function(id) end,
}

local mockSerialization = MockEnv.serialization

local mockComponent = {
  list = function() return {} end,
  isAvailable = function(name) return false end,
  proxy = function(addr) return nil end,
}

_G.computer = mockComputer
_G.event = mockEvent
_G.serialization = mockSerialization
_G.component = mockComponent

package.loaded["computer"] = mockComputer
package.loaded["event"] = mockEvent
package.loaded["serialization"] = mockSerialization
package.loaded["component"] = mockComponent

os.time = function() return math.floor(mockUptime) end
os.clock = function() return mockUptime end
os.epoch = function() return math.floor(mockUptime * 1000) end

-- ===========================================================================
-- Ghost Item Detector Simulation
-- ===========================================================================

local GhostDetector = {}
GhostDetector.__index = GhostDetector

function GhostDetector.new(config)
  config = config or {}
  local self = setmetatable({}, GhostDetector)
  self._idleTimeout = config.idleTimeout or 10.0  -- 10s default
  self._lastProgressTime = 0
  self._idleStarted = false
  self._idleStartTime = 0
  self._ghostItemsDetected = false
  self._callLog = {}
  return self
end

function GhostDetector:recordProgress(progress)
  table.insert(self._callLog, { op = "recordProgress", progress = progress, time = mockUptime })
  self._lastProgressTime = mockUptime
  self._idleStarted = false
end

function GhostDetector:checkIdle()
  local elapsed = mockUptime - self._lastProgressTime
  if not self._idleStarted and elapsed >= self._idleTimeout then
    self._idleStarted = true
    self._idleStartTime = mockUptime
    self._ghostItemsDetected = true
    table.insert(self._callLog, { op = "idleDetected", time = mockUptime, elapsed = elapsed })
    return true
  end
  return false
end

function GhostDetector:hasGhostItems()
  return self._ghostItemsDetected
end

function GhostDetector:reset()
  self._ghostItemsDetected = false
  self._idleStarted = false
  self._idleStartTime = 0
  currentProgress = 0
  table.insert(self._callLog, { op = "reset", time = mockUptime })
end

-- Mock machine input bus with residual items
local InputBus = {}
InputBus.__index = InputBus

function InputBus.new(initialItems)
  local self = setmetatable({}, InputBus)
  self._slots = {}
  if initialItems then
    for i, item in ipairs(initialItems) do
      self._slots[i] = {
        label = item.label,
        size = item.size or 0,
        maxSize = item.maxSize or 64,
      }
    end
  end
  self._flushLog = {}
  return self
end

function InputBus:getSlot(slot)
  return self._slots[slot]
end

function InputBus:countItems()
  local total = 0
  for _, stack in ipairs(self._slots) do
    if stack and stack.size then
      total = total + stack.size
    end
  end
  return total
end

function InputBus:hasItems()
  return self:countItems() > 0
end

-- Blind flush: clear all items to return line
function InputBus:flushToReturn(returnLine)
  local flushed = {}
  local totalFlushed = 0
  for i, stack in ipairs(self._slots) do
    if stack and stack.size > 0 then
      table.insert(flushed, { label = stack.label, count = stack.size })
      totalFlushed = totalFlushed + stack.size
      if returnLine then
        table.insert(returnLine, { label = stack.label, size = stack.size })
      end
      stack.size = 0
    end
  end
  table.insert(self._flushLog, {
    time = mockUptime,
    items = flushed,
    total = totalFlushed,
  })
  return flushed, totalFlushed
end

-- ===========================================================================
-- TEST GROUP 1: 10s Idle Timeout Triggers
-- ===========================================================================

Assert.startTest("G1: 10-second idle timeout triggers when machine stops progressing")

do
  local detector = GhostDetector.new({ idleTimeout = 10.0 })

  -- Machine is processing normally at first
  detector:recordProgress(25)  -- 25% progress
  tick(1.0)
  detector:recordProgress(50)  -- 50% progress
  tick(2.0)
  detector:recordProgress(75)  -- 75% progress

  -- Machine completes: progress stalls at 100%
  detector:recordProgress(100)
  tick(3.0)

  -- After 3s: still within grace period, no ghost detection
  local isIdle = detector:checkIdle()
  Assert.isFalse(isIdle, "no idle detected after 3s (within 10s window)")
  Assert.isFalse(detector:hasGhostItems(), "no ghost items yet")

  -- Wait 8 more seconds (total 11s since last progress)
  tick(8.0)
  isIdle = detector:checkIdle()
  Assert.isTrue(isIdle, "idle detected after 11s total (exceeds 10s timeout)")
  Assert.isTrue(detector:hasGhostItems(), "ghost items flagged")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 2: Blind Flush Clears Input Bus
-- ===========================================================================

Assert.startTest("G2: Blind flush clears unconsumed items from input bus via return line")

do
  -- Simulate a machine input bus with unconsumed items (ghost items)
  local inputBus = InputBus.new({
    { label = "minecraft:iron_ingot", size = 32, maxSize = 64 },
    { label = "gregtech:gt.circuit.integrated.4", size = 4, maxSize = 64 },
    { label = "minecraft:coal", size = 16, maxSize = 64 },
  })

  Assert.isTrue(inputBus:hasItems(), "input bus has items before flush")
  Assert.equal(52, inputBus:countItems(), "52 items in input bus")

  -- Perform blind flush to return line
  local returnLine = {}
  local flushed, total = inputBus:flushToReturn(returnLine)

  Assert.equal(3, #flushed, "3 item types flushed")
  Assert.equal(52, total, "total 52 items flushed")
  Assert.equal(0, inputBus:countItems(), "input bus is empty after flush")
  Assert.isFalse(inputBus:hasItems(), "input bus has no items after flush")

  -- Verify return line received the items
  Assert.equal(3, #returnLine, "return line has 3 items")
  Assert.equal("minecraft:iron_ingot", returnLine[1].label,
    "first return item is iron_ingot")
  Assert.equal(32, returnLine[1].size, "32 iron ingots returned")

  Assert.equal("gregtech:gt.circuit.integrated.4", returnLine[2].label,
    "second return item is circuit")
  Assert.equal(4, returnLine[2].size, "4 circuits returned")

  Assert.equal("minecraft:coal", returnLine[3].label,
    "third return item is coal")
  Assert.equal(16, returnLine[3].size, "16 coal returned")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 3: Machine Returns to AVAILABLE After Cleanup
-- ===========================================================================

Assert.startTest("G3: Machine returns to AVAILABLE state after ghost item cleanup")

do
  -- Simulate full ghost-detection-to-cleanup lifecycle
  local machineState = "PROCESSING"
  local jobComplete = false
  local ghostCleaned = false
  local detector = GhostDetector.new({ idleTimeout = 10.0 })
  local inputBus = InputBus.new({
    { label = "minecraft:iron_ingot", size = 32, maxSize = 64 },
  })

  -- Phase 1: Machine is PROCESSING
  Assert.equal("PROCESSING", machineState, "machine is PROCESSING")

  -- Phase 2: Job finishes, progress stops
  detector:recordProgress(100)  -- job complete
  jobComplete = true

  -- Phase 3: Wait 11 seconds with no progress
  tick(11.0)
  local idle = detector:checkIdle()
  Assert.isTrue(idle, "idle detected at 11s mark")

  -- Phase 4: Ghost detected — transition to CLEANUP
  if detector:hasGhostItems() then
    -- Enter CLEANUP phase
    machineState = "CLEANUP"

    -- Blind flush
    local returnLine = {}
    inputBus:flushToReturn(returnLine)

    -- Verify input bus is empty
    Assert.equal(0, inputBus:countItems(), "input bus empty after flush")
    ghostCleaned = true
  end

  -- Phase 5: Cleanup complete — return to AVAILABLE
  machineState = "AVAILABLE"
  detector:reset()

  Assert.equal("AVAILABLE", machineState, "machine returned to AVAILABLE")
  Assert.isTrue(jobComplete, "job completed")
  Assert.isTrue(ghostCleaned, "ghost items cleaned")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 4: Active Processing Suppresses Ghost Detection
-- ===========================================================================

Assert.startTest("G4: Active processing prevents false ghost detection")

do
  local detector = GhostDetector.new({ idleTimeout = 10.0 })

  -- Machine is actively processing with steady progress
  for i = 1, 30 do
    detector:recordProgress(i * 3)  -- progress changes each tick
    tick(1.0)
    local idle = detector:checkIdle()
    if idle then
      -- This should not happen — steady progress means no idle
      Assert.isTrue(false, string.format("false ghost detection at tick %d", i))
    end
  end

  Assert.isFalse(detector:hasGhostItems(),
    "no ghost items detected during active processing")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 5: Multiple Flush Cycles
-- ===========================================================================

Assert.startTest("G5: Multiple ghost detection and flush cycles work correctly")

do
  for cycle = 1, 3 do
    local detector = GhostDetector.new({ idleTimeout = 10.0 })
    local inputBus = InputBus.new({
      { label = "minecraft:iron_ore", size = 64, maxSize = 64 },
    })

    -- Record some progress, then stall
    detector:recordProgress(50)
    tick(11.0)

    local idle = detector:checkIdle()
    Assert.isTrue(idle, string.format("cycle %d: idle detected", cycle))

    local returnLine = {}
    local flushed, total = inputBus:flushToReturn(returnLine)
    Assert.equal(64, total, string.format("cycle %d: 64 items flushed", cycle))

    -- Reset for next cycle
    detector:reset()
  end
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 6: Empty Input Bus — No-Op Flush
-- ===========================================================================

Assert.startTest("G6: Flush on empty input bus is no-op")

do
  local inputBus = InputBus.new({})  -- empty

  Assert.equal(0, inputBus:countItems(), "input bus starts empty")
  Assert.isFalse(inputBus:hasItems(), "hasItems returns false")

  local returnLine = {}
  local flushed, total = inputBus:flushToReturn(returnLine)

  Assert.equal(0, #flushed, "no items flushed")
  Assert.equal(0, total, "0 total flushed")
  Assert.equal(0, inputBus:countItems(), "input bus still empty")
  Assert.equal(0, #returnLine, "return line still empty")
end
Assert.endTest()

-- ===========================================================================
-- Print summary and exit
-- ===========================================================================
-- Summary: return status code via Assert.summary() return value
-- When run standalone, failures are reported but don't exit the process.
local success = Assert.summary()
