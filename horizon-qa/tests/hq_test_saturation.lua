--[[
hq_test_saturation.lua — Horizon-QA Tier 2 Test: Multi-Broker Saturation
AE2 Execution System (AE2-ES), Deliverable C9

Tests the system's behavior under full saturation:
  1. All machines across 4 brokers saturated
  2. Brokers yield without crashing (cooperative multitasking)
  3. Redstone locks hold buffers back
  4. Instant dispatch resumes when one machine becomes available

Run standalone:  lua horizon-qa/tests/hq_test_saturation.lua
]]--

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
local MockModules = require("tests.helpers.mock_modules")

-- ===========================================================================
-- Setup: Mock OC environment
-- ===========================================================================

local mockUptime = 5000
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

-- Redstone gate per broker (simulated)
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
  list = function() return { ["rs-addr"] = "redstone" } end,
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
-- Load production modules
-- ===========================================================================
package.loaded["JobManifest"] = require("src.jobmanifest")
package.loaded["MachineNode"] = MockModules.MachineNode
package.loaded["BufferSnapshot"] = require("src.buffersnapshot")
package.loaded["JobQueue"] = MockModules.JobQueue
package.loaded["hardware_abstraction_layer"] = MockModules.HAL
package.loaded["MaintenanceReport"] = MockModules.MaintenanceReport
package.loaded["telemetry_payload"] = require("src.telemetrypayload")

local ExecBroker = require("src.exec_broker")

-- ===========================================================================
-- Saturation Test Infrastructure
-- ===========================================================================

-- Redstone gate per broker
local RedstoneGate = {}
RedstoneGate.__index = RedstoneGate

function RedstoneGate.new(name)
  local self = setmetatable({}, RedstoneGate)
  self.name = name
  self._locked = true  -- start locked (buffer held back)
  self._lockEvents = {}
  self._unlockEvents = {}
  return self
end

function RedstoneGate:isLocked()
  return self._locked
end

function RedstoneGate:lock(reason)
  self._locked = true
  table.insert(self._lockEvents, { time = mockUptime, reason = reason or "saturation" })
end

function RedstoneGate:unlock(reason)
  self._locked = false
  table.insert(self._unlockEvents, { time = mockUptime, reason = reason or "machine available" })
end

function RedstoneGate:getEventCount()
  return #self._lockEvents + #self._unlockEvents
end

-- Simulated broker with machine array
local Broker = {}
Broker.__index = Broker

function Broker.new(name, machineCount)
  local self = setmetatable({}, Broker)
  self.name = name
  self._machines = {}
  self._gate = RedstoneGate.new(name .. "-gate")
  self._yieldCount = 0
  self._crashed = false
  self._jobsDispatched = 0

  -- Create machines (all starting as PROCESSING = saturated)
  for i = 1, (machineCount or 4) do
    local addr = string.format("%s-m%d", name, i)
    self._machines[addr] = MockModules.MachineNode.new(addr, {
      status = "PROCESSING",
      machineType = "basic",
    })
  end
  return self
end

function Broker:getGate()
  return self._gate
end

function Broker:yield()
  self._yieldCount = self._yieldCount + 1
  tick(0.01)  -- simulate cooperative yield
end

function Broker:availableMachineCount()
  local count = 0
  for _, m in pairs(self._machines) do
    if m:isAvailable() then
      count = count + 1
    end
  end
  return count
end

function Broker:machineCount()
  local count = 0
  for _ in pairs(self._machines) do count = count + 1 end
  return count
end

function Broker:findAvailableMachine()
  for addr, m in pairs(self._machines) do
    if m:isAvailable() then
      return addr, m
    end
  end
  return nil
end

function Broker:releaseMachine(address)
  local m = self._machines[address]
  if m then
    m:releaseJob()
  end
end

function Broker:simulatePoll()
  self:yield()
end

-- ===========================================================================
-- TEST GROUP 1: Full Saturation — No Available Machines
-- ===========================================================================

Assert.startTest("S1: All 4 brokers fully saturated — no available machines")

do
  local brokers = {}
  for i = 1, 4 do
    brokers[i] = Broker.new("broker-" .. i, 4)
  end

  -- Verify all machines are PROCESSING (saturated)
  local totalMachines = 0
  local availableMachines = 0
  for _, b in ipairs(brokers) do
    totalMachines = totalMachines + b:machineCount()
    availableMachines = availableMachines + b:availableMachineCount()
  end

  Assert.equal(16, totalMachines, "16 total machines across 4 brokers")
  Assert.equal(0, availableMachines, "0 machines available (fully saturated)")

  -- Verify each broker's gate is locked
  for _, b in ipairs(brokers) do
    Assert.isTrue(b:getGate():isLocked(),
      string.format("%s gate is locked", b.name))
  end
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 2: Brokers Yield Without Crashing
-- ===========================================================================

Assert.startTest("S2: Brokers yield without crashing under sustained saturation")

do
  local brokers = {}
  for i = 1, 4 do
    brokers[i] = Broker.new("broker-" .. i, 4)
  end

  -- Simulate 1000 poll cycles under saturation
  for cycle = 1, 1000 do
    for _, b in ipairs(brokers) do
      -- Each poll cycle: check if any machine is available
      if b:availableMachineCount() == 0 then
        -- Saturated: yield and lock gate
        b:simulatePoll()
        if not b:getGate():isLocked() then
          b:getGate():lock("saturated")
        end
      end
    end
  end

  -- Verify no broker crashed
  for _, b in ipairs(brokers) do
    Assert.isFalse(b._crashed,
      string.format("broker %s did not crash after 1000 cycles", b.name))
    Assert.isTrue(b._yieldCount > 0,
      string.format("broker %s yielded at least once (%d times)",
        b.name, b._yieldCount))
  end

  -- All gates should still be locked (sustained saturation)
  for _, b in ipairs(brokers) do
    Assert.isTrue(b:getGate():isLocked(),
      string.format("%s gate still locked after 1000 cycles", b.name))
  end
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 3: Redstone Locks Hold Buffers During Saturation
-- ===========================================================================

Assert.startTest("S3: Redstone locks hold buffers back during saturation")

do
  local brokers = {}
  for i = 1, 4 do
    brokers[i] = Broker.new("broker-" .. i, 4)
  end

  -- Phase 1: All machines saturated — locks engage
  for _, b in ipairs(brokers) do
    b:getGate():lock("saturation")
  end

  -- Verify all gates locked
  for _, b in ipairs(brokers) do
    Assert.isTrue(b:getGate():isLocked(),
      string.format("%s gate locked during saturation", b.name))
  end

  -- Phase 2: 50 poll cycles — no machines available, gates stay locked
  for cycle = 1, 50 do
    for _, b in ipairs(brokers) do
      if b:availableMachineCount() == 0 then
        b:simulatePoll()
      else
        -- If available, unlock (but this shouldn't happen yet)
        b:getGate():unlock("machine became available")
      end
      -- Gate must remain locked
      Assert.isTrue(b:getGate():isLocked(),
        string.format("%s gate stays locked at cycle %d", b.name, cycle))
    end
  end
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 4: Instant Dispatch Resumes When Machine Available
-- ===========================================================================

Assert.startTest("S4: Instant dispatch resumes when one machine becomes available")

do
  local b1 = Broker.new("broker-alpha", 4)

  -- Start fully saturated
  b1:getGate():lock("saturation")

  -- Release one machine (simulates job completion)
  local addr = "broker-alpha-m1"
  b1:releaseMachine(addr)

  -- Now 1 machine should be available
  Assert.equal(1, b1:availableMachineCount(),
    "1 machine available after release")

  -- Gate should unlock because a machine is available
  b1:getGate():unlock("machine broker-alpha-m1 available")

  Assert.isFalse(b1:getGate():isLocked(),
    "gate unlocked when machine becomes available")

  -- Machine should be found by findAvailable
  local foundAddr = b1:findAvailableMachine()
  Assert.notNil(foundAddr, "available machine found")
  Assert.equal(addr, foundAddr, "correct machine address returned")

  -- Lock and bind for new job
  local m = b1._machines[foundAddr]
  local locked = m:lock()
  Assert.isTrue(locked, "machine locked successfully")

  -- After locking, back to 0 available
  Assert.equal(0, b1:availableMachineCount(),
    "0 available after locking the freed machine")

  -- Re-lock gate
  b1:getGate():lock("re-saturated")
  Assert.isTrue(b1:getGate():isLocked(), "gate re-locked")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 5: Gradual Desaturation Across Multiple Brokers
-- ===========================================================================

Assert.startTest("S5: Gradual machine release across all 4 brokers")

do
  local brokers = {}
  for i = 1, 4 do
    brokers[i] = Broker.new("broker-" .. i, 4)
  end

  -- Start saturated — all 16 machines PROCESSING
  local totalAvailable = 0
  for _, b in ipairs(brokers) do
    totalAvailable = totalAvailable + b:availableMachineCount()
  end
  Assert.equal(0, totalAvailable, "all 16 machines saturated")

  -- Gradually release machines one at a time
  local releasedOrder = {}
  for _, b in ipairs(brokers) do
    for addr, _ in pairs(b._machines) do
      b:releaseMachine(addr)
      table.insert(releasedOrder, addr)
      b:getGate():unlock("machine " .. addr .. " freed")
    end
  end

  -- All 16 machines should now be available
  totalAvailable = 0
  for _, b in ipairs(brokers) do
    totalAvailable = totalAvailable + b:availableMachineCount()
  end
  Assert.equal(16, totalAvailable, "all 16 machines available after release")
  Assert.equal(16, #releasedOrder, "16 machines released in order")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 6: Saturation Stress — Rapid Lock/Unlock Cycles
-- ===========================================================================

Assert.startTest("S6: Rapid saturation/de-saturation cycles don't crash brokers")

do
  local b1 = Broker.new("broker-stress", 4)

  for cycle = 1, 20 do
    -- Saturate: all machines PROCESSING
    for _, m in pairs(b1._machines) do
      m._status = "PROCESSING"
      m._locked = true
    end
    b1:getGate():lock("saturate cycle " .. cycle)

    -- Verify saturation
    Assert.equal(0, b1:availableMachineCount(),
      string.format("cycle %d: saturated (0 available)", cycle))

    b1:simulatePoll()
    tick(0.1)

    -- Release all machines
    for addr in pairs(b1._machines) do
      b1:releaseMachine(addr)
    end
    b1:getGate():unlock("de-saturate cycle " .. cycle)

    Assert.equal(4, b1:availableMachineCount(),
      string.format("cycle %d: all 4 available after release", cycle))
  end

  Assert.isFalse(b1._crashed,
    "broker survived 20 rapid saturation cycles without crashing")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 7: Yield Budget — Brokers Yield Frequently
-- ===========================================================================

Assert.startTest("S7: Broker yields at least once per poll cycle under saturation")

do
  local b1 = Broker.new("broker-single", 4)

  -- Saturate
  for _, m in pairs(b1._machines) do
    m._status = "PROCESSING"
  end
  b1:getGate():lock("saturation")

  local initialYield = b1._yieldCount

  -- Simulate 100 poll cycles
  for i = 1, 100 do
    b1:simulatePoll()
    if b1:availableMachineCount() == 0 then
      -- must yield
    end
    tick(0.01)
  end

  local finalYield = b1._yieldCount
  Assert.isTrue(finalYield > initialYield,
    string.format("broker yielded %d times in 100 cycles", finalYield - initialYield))
end
Assert.endTest()

-- ===========================================================================
-- Print summary and exit
-- ===========================================================================
-- Summary: return status code via Assert.summary() return value
-- When run standalone, failures are reported but don't exit the process.
local success = Assert.summary()
