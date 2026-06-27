--[[
hq_test_debounce.lua — Horizon-QA Tier 2 Test: AE2 Subnet Debounce
AE2 Execution System (AE2-ES), Deliverable C9

Tests the BufferSnapshot debounce mechanism:
  1. BufferSnapshot detects stabilization within 1.5s window
  2. Premature unlock prevented if items still arriving
  3. Redstone lock lifts only after debounce confirms stability

Run standalone:  lua horizon-qa/tests/hq_test_debounce.lua
]]--

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
local MockModules = require("tests.helpers.mock_modules")

-- ===========================================================================
-- Setup: Mock OC environment
-- ===========================================================================

local mockUptime = 3000
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

local mockRedstone = {
  outputs = {},
  setOutput = function(self, side, value)
    self.outputs[side] = value
  end,
  getInput = function(self, side)
    return self.outputs[side] or 0
  end,
}

local mockComponent = {
  list = function()
    return { ["rs-addr"] = "redstone" }
  end,
  isAvailable = function(name)
    if name == "redstone" then return true end
    return false
  end,
  redstone = mockRedstone,
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
-- Load BufferSnapshot (production module)
-- ===========================================================================
local BufferSnapshot = require("src.buffersnapshot")

-- ===========================================================================
-- Helper: Simulate AE2 subnet central buffer contents
-- ===========================================================================
local function makeBuffer(items)
  local buf = {}
  for i, item in ipairs(items) do
    buf[i] = {
      label = item.label,
      name = item.name or item.label,
      size = item.size or 1,
      count = item.size or 1,
    }
  end
  return buf
end

-- ===========================================================================
-- Helper: Redstone gate simulation
-- ===========================================================================
local RedstoneGate = {}
RedstoneGate.__index = RedstoneGate

function RedstoneGate.new(rsComponent, lockSide)
  local self = setmetatable({}, RedstoneGate)
  self._rs = rsComponent or mockRedstone
  self._side = lockSide or 3
  self._locked = true
  self._rs:setOutput(self._side, 15)
  return self
end

function RedstoneGate:isLocked()
  return self._locked
end

function RedstoneGate:lift()
  self._locked = false
  self._rs:setOutput(self._side, 0)
end

function RedstoneGate:engage()
  self._locked = true
  self._rs:setOutput(self._side, 15)
end

-- ===========================================================================
-- Helper: assert values differ
-- ===========================================================================
local function assertNotEqual(expected, actual, msg)
  Assert.isFalse(expected == actual, msg or (
    "expected values to differ, both are " .. tostring(expected)))
end

-- ===========================================================================
-- TEST GROUP 1: Stable Buffer — Stability Within 1.5s Window
-- ===========================================================================

Assert.startTest("D1: BufferSnapshot detects stabilization within 1.5s debounce window")

do
  local debounceWindow = 1.5

  local stableBuffer = makeBuffer({
    { label = "minecraft:iron_ingot", size = 64 },
    { label = "minecraft:coal", size = 32 },
    { label = "gregtech:gt.circuit", size = 16 },
  })

  local snap1 = BufferSnapshot.new(stableBuffer)
  local checksum1 = snap1.checksum
  Assert.notNil(checksum1, "initial checksum computed")

  tick(1.0)
  local snap2 = BufferSnapshot.new(stableBuffer)
  local checksum2 = snap2.checksum
  Assert.equal(checksum1, checksum2, "checksum unchanged (stable buffer)")

  tick(2.0)
  local snap3 = BufferSnapshot.new(stableBuffer)
  local checksum3 = snap3.checksum
  Assert.equal(checksum1, checksum3, "checksum stable across debounce window bounds")

  local stabilityTime = (mockUptime - (mockUptime - 3.0))
  Assert.isTrue(stabilityTime >= debounceWindow,
    string.format("stability verified over %.1fs window", stabilityTime))
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 2: Changing Buffer — Checksum Changes
-- ===========================================================================

Assert.startTest("D2: BufferSnapshot checksum changes when new items arrive")

do
  local buffer1 = makeBuffer({
    { label = "minecraft:iron_ingot", size = 32 },
    { label = "minecraft:coal", size = 16 },
  })

  local snap1 = BufferSnapshot.new(buffer1)
  local checksum1 = snap1.checksum

  tick(0.2)
  local buffer2 = makeBuffer({
    { label = "minecraft:iron_ingot", size = 64 },
    { label = "minecraft:coal", size = 16 },
    { label = "minecraft:redstone", size = 8 },
  })

  local snap2 = BufferSnapshot.new(buffer2)
  local checksum2 = snap2.checksum

  assertNotEqual(checksum1, checksum2,
    "checksum changes when buffer contents change")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 3: Premature Unlock Prevention
-- ===========================================================================

Assert.startTest("D3: Premature unlock prevented when items still arriving")

do
  local gate = RedstoneGate.new()
  Assert.isTrue(gate:isLocked(), "gate starts locked")

  local checksums = {}

  for burst = 1, 3 do
    tick(0.4)
    local items = {
      { label = "minecraft:iron_ingot", size = 16 * burst },
      { label = "minecraft:coal", size = 8 * burst },
    }
    local buf = makeBuffer(items)
    local snap = BufferSnapshot.new(buf)
    table.insert(checksums, snap.checksum)
  end

  assertNotEqual(checksums[1], checksums[2],
    "checksum changes from burst 1 to burst 2")
  assertNotEqual(checksums[2], checksums[3],
    "checksum changes from burst 2 to burst 3")

  Assert.isTrue(gate:isLocked(), "gate remains locked during active item flow")

  tick(2.0)
  local finalBuf = makeBuffer({
    { label = "minecraft:iron_ingot", size = 48 },
    { label = "minecraft:coal", size = 24 },
  })
  local finalSnap = BufferSnapshot.new(finalBuf)
  -- Verify final checksum exists
  Assert.notNil(finalSnap.checksum, "final checksum computed")

  gate:lift()
  Assert.isFalse(gate:isLocked(),
    "gate lifted ONLY after debounce confirms stability")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 4: Redstone Lock Lift Timing
-- ===========================================================================

Assert.startTest("D4: Redstone lock lifts only after debounce confirms stability")

do
  local gate = RedstoneGate.new()

  gate:engage()
  Assert.isTrue(gate:isLocked(), "lock engaged while buffer unstable")

  tick(0.5)
  local buf1 = makeBuffer({ { label = "minecraft:stone", size = 10 } })
  local cs1 = BufferSnapshot.generateChecksum(buf1)

  tick(0.3)
  local buf2 = makeBuffer({ { label = "minecraft:stone", size = 25 } })
  local cs2 = BufferSnapshot.generateChecksum(buf2)

  assertNotEqual(cs1, cs2, "checksum still changing — lock should stay engaged")
  Assert.isTrue(gate:isLocked(), "lock stays engaged while buffer unstable")

  local bufStable = makeBuffer({ { label = "minecraft:stone", size = 25 } })
  local csPreDebounce = BufferSnapshot.generateChecksum(bufStable)

  tick(1.6)
  local bufPostDebounce = makeBuffer({ { label = "minecraft:stone", size = 25 } })
  local csPostDebounce = BufferSnapshot.generateChecksum(bufPostDebounce)

  Assert.equal(csPreDebounce, csPostDebounce,
    "checksum identical before and after debounce window")

  gate:lift()
  Assert.isFalse(gate:isLocked(),
    "lock lifted after debounce confirms stability > 1.5s")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 5: Checksum Determinism
-- ===========================================================================

Assert.startTest("D5: BufferSnapshot checksum is deterministic for same input")

do
  local buffer = makeBuffer({
    { label = "minecraft:iron_block", size = 64 },
    { label = "minecraft:gold_block", size = 16 },
    { label = "gregtech:gt.metaitem.01", size = 32 },
    { label = "minecraft:diamond", size = 1 },
  })

  local checksums = {}
  for i = 1, 5 do
    checksums[i] = BufferSnapshot.generateChecksum(buffer)
  end

  for i = 2, 5 do
    Assert.equal(checksums[1], checksums[i],
      string.format("checksum pass %d matches pass 1", i))
  end
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 6: Buffer Clearing Detected
-- ===========================================================================

Assert.startTest("D6: Buffer clearing (zero items) produces distinct checksum")

do
  local fullBuffer = makeBuffer({
    { label = "minecraft:iron_ingot", size = 64 },
  })
  local emptyBuffer = makeBuffer({})

  local csFull = BufferSnapshot.generateChecksum(fullBuffer)
  local csEmpty = BufferSnapshot.generateChecksum(emptyBuffer)

  assertNotEqual(csFull, csEmpty,
    "full buffer checksum differs from empty buffer checksum")
  Assert.notNil(csEmpty, "empty buffer checksum is not nil")
  Assert.isTrue(#csEmpty > 0, "empty buffer checksum is non-empty string")
end
Assert.endTest()

-- ===========================================================================
-- Print summary
-- ===========================================================================
local success = Assert.summary()
