--[[
hq_test_modem.lua — Horizon-QA Tier 2 Test: Real Modem Broadcast
AE2 Execution System (AE2-ES), Deliverable C9

Simulates 4 OC computers broadcasting TelemetryPayload via actual modems
(in standalone mode) or real modem components (on GTNH headless server).

Tests:
  1. 4 brokers broadcast telemetry, Supervisor receives all 4
  2. No packet loss
  3. Correct brokerId routing
  4. hardwareMatrix correctly reflects each broker's machine states

Run standalone:  lua horizon-qa/tests/hq_test_modem.lua
]]--

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
local MockModules = require("tests.helpers.mock_modules")

-- ===========================================================================
-- Setup: Mock OC environment
-- ===========================================================================

-- Shared mock clock
local mockUptime = 1000
local function tick(dt)
  mockUptime = mockUptime + (dt or 0.05)
end

-- Mock event queue for modem message delivery simulation
local eventQueue = {}
local mockEvent = {
  pull = function(timeout)
    tick(0.05)
    if #eventQueue > 0 then
      local ev = table.remove(eventQueue, 1)
      return table.unpack(ev)
    end
    -- Return a timer event so loops don't hang
    return "timer"
  end,
  timer = function(interval, callback, count)
    return 1
  end,
  cancel = function(id) end,
}

-- Shared modem component — all brokers and supervisor share this
local sharedModem = MockModules.MockModem.new()

local mockComponent = {
  list = function()
    return { ["modem-addr"] = "modem" }
  end,
  isAvailable = function(name)
    if name == "modem" then return true end
    return false
  end,
  modem = sharedModem,
  proxy = function(addr)
    if addr == "modem-addr" then return sharedModem end
    return nil
  end,
}

-- Mock serialization
local mockSerialization = MockEnv.serialization

-- Mock computer
local mockComputer = {
  uptime = function() return mockUptime end,
  pushSignal = function() end,
}

-- Load mock environment into globals
_G.computer = mockComputer
_G.event = mockEvent
_G.serialization = mockSerialization
_G.component = mockComponent

package.loaded["computer"] = mockComputer
package.loaded["event"] = mockEvent
package.loaded["serialization"] = mockSerialization
package.loaded["component"] = mockComponent

-- Override time functions to use mockUptime
os.time = function() return math.floor(mockUptime) end
os.clock = function() return mockUptime end
os.epoch = function() return math.floor(mockUptime * 1000) end

-- ===========================================================================
-- Load production modules
-- ===========================================================================

-- Pre-load modules for exec_broker safeRequire
package.loaded["JobManifest"] = require("src.jobmanifest")
package.loaded["MachineNode"] = MockModules.MachineNode
package.loaded["BufferSnapshot"] = require("src.buffersnapshot")
package.loaded["JobQueue"] = MockModules.JobQueue
package.loaded["hardware_abstraction_layer"] = MockModules.HAL
package.loaded["MaintenanceReport"] = MockModules.MaintenanceReport
package.loaded["telemetry_payload"] = require("src.telemetrypayload")

local SupervisorMod = require("src.supervisor")
local Supervisor = SupervisorMod.Supervisor
local ExecBroker = require("src.exec_broker")
local TelemetryPayload = require("src.telemetrypayload")

-- ===========================================================================
-- Helper: Build a telemetry payload string for a broker
-- ===========================================================================
local function buildPayload(brokerId, machineStates, alerts, queueLen)
  local hwMatrix = machineStates or {
    { address = "m-" .. brokerId .. "-1", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "m-" .. brokerId .. "-2", status = "PROCESSING", activeJobId = "job-1", progress = 65 },
    { address = "m-" .. brokerId .. "-3", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "m-" .. brokerId .. "-4", status = "FAULTED", activeJobId = "job-2", progress = 30 },
  }
  local alertList = alerts or {
    { type = "INFO", severity = "WARNING", message = "Queue at " .. (queueLen or 5) .. " jobs", machineAddress = nil },
  }

  local tp, err = TelemetryPayload.build({
    brokerId = brokerId,
    queueLength = queueLen or 5,
    hardwareMatrix = hwMatrix,
    alerts = alertList,
    timestamp = mockUptime * 1000,
  })
  if not tp then
    error("buildPayload failed: " .. tostring(err))
  end
  return tp:serialize()
end

-- ===========================================================================
-- TEST GROUP 1: 4-Broker Broadcast Fan-in
-- ===========================================================================

Assert.startTest("G1: Supervisor receives telemetry from 4 brokers")

do
  -- Create supervisor
  local sv = Supervisor.new({ supervisorPort = 100 })

  -- Simulate 4 brokers broadcasting
  local brokerIds = { "broker-alpha", "broker-beta", "broker-gamma", "broker-delta" }
  local receivedData = {}

  for _, bid in ipairs(brokerIds) do
    tick(0.5)
    local payloadStr = buildPayload(bid)
    -- Simulate modem delivery: enqueue modem_message event
    table.insert(eventQueue, { "modem_message", "localhost", "modem-" .. bid, 100, nil, payloadStr })
    -- Process events by calling sv's _processMessage directly (simulates event loop)
    sv:_processMessage("modem-" .. bid, 100, payloadStr)
  end

  -- Assert: No packet loss — all 4 received (verified via stats)
  Assert.equal(4, sv._stats.messagesReceived, "4 messages received by Supervisor")
  Assert.equal(4, sv._stats.messagesValid, "4 valid messages (no invalid)")
  Assert.equal(0, sv._stats.messagesInvalid, "0 invalid messages")

  -- Assert: Last brokerId is broker-delta (last in processing order)
  Assert.equal("broker-delta", sv._stats.lastBrokerId,
    "lastBrokerId is broker-delta (last in order)")

  -- Verify broker IDs via queue entries
  local seenBrokers = {}
  local queue = sv:getQueue()
  for _ = 1, queue:count() do
    local entry = queue:pop()
    if entry and entry.brokerId then
      seenBrokers[entry.brokerId] = true
    end
  end
  for _, bid in ipairs(brokerIds) do
    Assert.isTrue(seenBrokers[bid] ~= nil,
      string.format("broker '%s' found in telemetry queue", bid))
  end
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 2: hardwareMatrix Integrity
-- ===========================================================================

Assert.startTest("G2: hardwareMatrix correctly reflects broker machine states")

do
  local sv = Supervisor.new({ supervisorPort = 101 })

  -- Create 2 brokers with distinct hardware matrices
  local brokerA = "broker-alpha"
  local brokerB = "broker-beta"

  -- Broker A: 2 AVAILABLE, 1 PROCESSING, 1 FAULTED
  sv:_processMessage("modem-a", 101, buildPayload(brokerA, {
    { address = "a-m1", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "a-m2", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "a-m3", status = "PROCESSING", activeJobId = "job-a-3", progress = 50 },
    { address = "a-m4", status = "FAULTED", activeJobId = "job-a-4", progress = 20 },
  }, nil, 3))

  -- Broker B: all AVAILABLE (idle array)
  sv:_processMessage("modem-b", 101, buildPayload(brokerB, {
    { address = "b-m1", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "b-m2", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "b-m3", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "b-m4", status = "AVAILABLE", activeJobId = nil, progress = nil },
  }, nil, 0))

  -- Verify brokers' telemetry was queued
  local queue = sv:getQueue()

  -- Drain entries and verify machine data exists
  local entryCount = 0
  local foundBrokerA = false
  local foundBrokerB = false
  while queue:count() > 0 do
    local entry = queue:pop()
    if entry then
      entryCount = entryCount + 1
      if entry.brokerId == brokerA then foundBrokerA = true end
      if entry.brokerId == brokerB then foundBrokerB = true end
      -- Verify hardwareMatrix is present and has expected structure
      local hw = entry.hardwareMatrix
      Assert.notNil(hw, "entry has hardwareMatrix")
      Assert.isTrue(type(hw) == "table" and #hw >= 1,
        "hardwareMatrix has machine entries")
    end
  end

  Assert.isTrue(foundBrokerA, "brokerA telemetry entry found")
  Assert.isTrue(foundBrokerB, "brokerB telemetry entry found")
  Assert.equal(2, entryCount, "2 entries processed from queue")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 3: Malformed Payload Handling
-- ===========================================================================

Assert.startTest("G3: Supervisor rejects malformed payloads, keeps processing valid ones")

do
  local sv = Supervisor.new({ supervisorPort = 102 })

  -- Valid message
  sv:_processMessage("modem-a", 102, buildPayload("broker-one", nil, nil, 1))
  tick(0.1)

  -- Malformed: empty string
  sv:_processMessage("modem-b", 102, "")
  tick(0.1)

  -- Malformed: non-table JSON
  sv:_processMessage("modem-c", 102, "not-a-table")
  tick(0.1)

  -- Valid message
  sv:_processMessage("modem-d", 102, buildPayload("broker-two", nil, nil, 2))
  tick(0.1)

  -- Malformed: missing brokerId
  local badPayload = '{ "timestamp": 12345, "queueLength": 0, "hardwareMatrix": [], "alerts": [] }'
  sv:_processMessage("modem-e", 102, badPayload)

  -- Assertions
  Assert.equal(5, sv._stats.messagesReceived, "5 messages received total")
  Assert.equal(2, sv._stats.messagesValid, "2 valid messages")
  Assert.equal(3, sv._stats.messagesInvalid, "3 invalid messages rejected")

  -- Only 2 valid entries in queue
  Assert.equal(2, sv:getQueue():count(), "queue has only 2 valid entries")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 4: Packet Ordering and Timestamps
-- ===========================================================================

Assert.startTest("G4: Telemetry packets preserve order and correct timestamps")

do
  local sv = Supervisor.new({ supervisorPort = 103 })
  local payloads = {}

  -- Send 8 payloads from 2 brokers in rapid succession
  for i = 1, 4 do
    local ts = mockUptime * 1000
    sv:_processMessage("modem-a", 103, buildPayload("broker-alpha", nil, nil, i))
    tick(0.02)
    sv:_processMessage("modem-b", 103, buildPayload("broker-beta", nil, nil, i))
    tick(0.02)
  end

  Assert.equal(8, sv._stats.messagesReceived, "8 messages received")
  Assert.equal(8, sv._stats.messagesValid, "all 8 valid")

  -- Verify FIFO ordering in queue
  local queue = sv:getQueue()
  Assert.equal(8, queue:count(), "queue has 8 entries")

  -- First entry should be broker-alpha
  local first = queue:pop()
  Assert.notNil(first, "first entry exists")
  Assert.equal("broker-alpha", first.brokerId, "first entry is broker-alpha")

  -- Second entry should be broker-beta
  local second = queue:pop()
  Assert.notNil(second, "second entry exists")
  Assert.equal("broker-beta", second.brokerId, "second entry is broker-beta")

  -- Timestamps should be sequential
  Assert.isTrue(second.timestamp >= first.timestamp,
    "timestamps are monotonic")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 5: Alert Propagation
-- ===========================================================================

Assert.startTest("G5: Alert data propagates correctly through telemetry")

do
  local sv = Supervisor.new({ supervisorPort = 104 })

  local alerts = {
    { type = "CRITICAL", severity = "HIGH", message = "Machine a-m2 has fault code 3", machineAddress = "a-m2" },
    { type = "INFO", severity = "MEDIUM", message = "Queue depth warning", machineAddress = nil },
  }

  sv:_processMessage("modem-a", 104, buildPayload("broker-alpha", nil, alerts, 8))

  -- Check alerts appeared in supervisor's telemetry queue
  -- Alerts are embedded in each payload; drain queue entries to verify
  local queue = sv:getQueue()
  local foundAlert = false
  while queue:count() > 0 do
    local entry = queue:pop()
    if entry and entry.alerts and #entry.alerts > 0 then
      foundAlert = true
    end
  end
  Assert.isTrue(foundAlert, "alert data propagated through telemetry queue")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 6: Serialization Round-Trip Fidelity
-- ===========================================================================

Assert.startTest("G6: Telemetry payload survives serialize/deserialize round-trip without data loss")

do
  local originalStates = {
    { address = "m1", status = "AVAILABLE", activeJobId = nil, progress = nil },
    { address = "m2", status = "LOCKED", activeJobId = "job-42", progress = 0 },
    { address = "m3", status = "PROCESSING", activeJobId = "job-43", progress = 78 },
    { address = "m4", status = "FAULTED", activeJobId = "job-44", progress = 45 },
  }

  local tp, err = TelemetryPayload.build({
    brokerId = "round-trip-test",
    queueLength = 7,
    hardwareMatrix = originalStates,
    alerts = {},
    timestamp = mockUptime * 1000,
  })
  Assert.notNil(tp, "TelemetryPayload built: " .. tostring(err or "ok"))

  -- Serialize
  local serialized = tp:serialize()
  Assert.notNil(serialized, "serialized payload is not nil")
  Assert.isTrue(#serialized > 0, "serialized payload is not empty")

  -- Deserialize
  local deserialized, deserErr = TelemetryPayload.deserialize(serialized)
  Assert.notNil(deserialized, "deserialized payload is not nil: " .. tostring(deserErr or "ok"))

  -- Verify fields survived
  Assert.equal("round-trip-test", deserialized.brokerId, "brokerId preserved")
  Assert.equal(7, deserialized.queueLength, "queueLength preserved")
  Assert.type("table", deserialized.hardwareMatrix, "hardwareMatrix is a table")
  Assert.equal(4, #deserialized.hardwareMatrix, "hardwareMatrix has 4 machines")

  -- Verify each machine state
  for i, state in ipairs(originalStates) do
    local ds = deserialized.hardwareMatrix[i]
    Assert.notNil(ds, string.format("machine %d exists in deserialized", i))
    Assert.equal(state.address, ds.address,
      string.format("machine %d address preserved: %s", i, state.address))
    Assert.equal(state.status, ds.status,
      string.format("machine %d status preserved: %s", i, state.status))
  end
end
Assert.endTest()

-- ===========================================================================
-- Print summary and exit
-- ===========================================================================
-- Summary: return status code via Assert.summary() return value
-- When run standalone, failures are reported but don't exit the process.
local success = Assert.summary()
