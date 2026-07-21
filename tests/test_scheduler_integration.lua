-- test_scheduler_integration.lua
-- ExecBroker integration with the cooperative time-slice scheduler.
-- Scheduler is now always-on; tests inject a mock to verify budget
-- control across phase module loops.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
local MockModules = require("tests.helpers.mock_modules")
MockEnv.setup()

local ExecBroker = require("src.exec_broker")

local function modules()
  return {
    JobManifest = MockModules.JobManifest,
    MachineNode = MockModules.MachineNode,
    BufferSnapshot = MockModules.BufferSnapshot,
    JobQueue = MockModules.JobQueue,
    HAL = MockModules.HAL,
    MaintenanceReport = MockModules.MaintenanceReport,
    TelemetryPayload = require("src.telemetrypayload"),
  }
end

local function newBroker(config)
  config = config or {}
  return ExecBroker.new({
    brokerId = "scheduler-integration",
    machines = {
      { laneId = "lane-a", machineAddr = "machine-a" },
      { laneId = "lane-b", machineAddr = "machine-b" },
    },
    modules = modules(),
    heartbeatInterval = 999,
    pollInterval = 999,
    useProgramFramework = config.useProgramFramework,
    timeSliceScheduler = config.timeSliceScheduler,
  })
end

Assert.startTest("ExecBroker always creates a scheduler")
do
  local broker = newBroker()
  Assert.isNonNil(broker._timeSliceScheduler,
    "Broker always creates a scheduler")
end
Assert.endTest()

Assert.startTest("ExecBroker resets scheduler budget each tick")
do
  local resets = 0
  local scheduler = {
    resets = resets,
    reset = function(self)
      resets = resets + 1
    end,
    remaining = function() return 1 end,
  }
  local broker = newBroker({
    useProgramFramework = true,
    timeSliceScheduler = scheduler,
  })

  broker:tick()

  Assert.greaterThan(0, resets, "Scheduler budget reset each tick")
end
Assert.endTest()

Assert.startTest("ExecBroker telemetry uses scheduler:forEach")
do
  local forEachCalls = 0
  local scheduler = {
    reset = function() end,
    remaining = function() return 1 end,
    forEach = function(_, list, fn)
      forEachCalls = forEachCalls + 1
      -- Actually iterate so telemetry builds the matrix
      for _, item in ipairs(list) do fn(item) end
      return #list
    end,
    forEachPair = function(_, tbl, fn)
      for k, v in pairs(tbl) do
        local _, stop = pcall(fn, k, v)
        if stop == false then break end
      end
      return 0
    end,
  }
  local broker = newBroker({
    timeSliceScheduler = scheduler,
  })
  local payloads = {}
  broker._M.TelemetryPayload = {
    build = function(params)
      table.insert(payloads, params)
      return { transmit = function() end }
    end,
  }

  broker:_transmitTelemetry()

  Assert.greaterThan(0, forEachCalls, "Telemetry uses scheduler:forEach")
  Assert.equal(1, #payloads, "Telemetry still broadcasts")
  Assert.hasKey(payloads[1].machines, "lane-a", "Telemetry includes lane-a")
  Assert.hasKey(payloads[1].machines, "lane-b", "Telemetry includes lane-b")
end
Assert.endTest()

return true
