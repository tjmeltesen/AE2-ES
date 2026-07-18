-- test_scheduler_integration.lua
-- Task 10: ExecBroker integration with the cooperative scheduler.

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
    useTimeSliceScheduler = config.useTimeSliceScheduler,
    useProgramFramework = config.useProgramFramework,
    timeSliceScheduler = config.timeSliceScheduler,
  })
end

Assert.startTest("ExecBroker keeps scheduler disabled by default")
do
  local broker = newBroker()
  Assert.isNil(broker._timeSliceScheduler,
    "Legacy broker path must not create a scheduler")
end
Assert.endTest()

Assert.startTest("ExecBroker budgets active jobs and telemetry without event pulls")
do
  local scheduler = {
    resets = 0,
    remainingCalls = 0,
    reset = function(self)
      self.resets = self.resets + 1
    end,
    remaining = function(self)
      self.remainingCalls = self.remainingCalls + 1
      return 1
    end,
    sleep = function()
      error("broker ticks must not ask the scheduler to yield")
    end,
  }

  local broker = newBroker({
    useTimeSliceScheduler = true,
    useProgramFramework = true,
    timeSliceScheduler = scheduler,
  })
  local processingCalls, cleanupCalls, telemetryCalls = 0, 0, 0
  broker._activeJobs = {
    ["lane-a"] = { phase = ExecBroker.PHASES.PROCESSING },
    ["lane-b"] = { phase = ExecBroker.PHASES.CLEANUP },
  }
  broker._checkProcessingJob = function()
    processingCalls = processingCalls + 1
  end
  broker._cleanupJob = function()
    cleanupCalls = cleanupCalls + 1
  end
  broker._M.TelemetryPayload = {
    build = function()
      telemetryCalls = telemetryCalls + 1
      return { transmit = function() end }
    end,
  }

  local originalSleep = os.sleep
  local sleepCalls = 0
  os.sleep = function()
    sleepCalls = sleepCalls + 1
  end

  local originalEvent = package.loaded["event"]
  local eventPullCalls = 0
  package.loaded["event"] = {
    pull = function()
      eventPullCalls = eventPullCalls + 1
    end,
  }

  broker:tick()

  os.sleep = originalSleep
  package.loaded["event"] = originalEvent

  Assert.equal(1, scheduler.resets, "Scheduler starts a fresh budget each tick")
  Assert.greaterThan(0, scheduler.remainingCalls,
    "Active-job and telemetry hotspots consult the scheduler budget")
  Assert.equal(1, processingCalls, "PROCESSING remains active every tick")
  Assert.equal(1, cleanupCalls, "CLEANUP remains active every tick")
  Assert.equal(1, telemetryCalls, "Telemetry remains eligible on the tick")
  Assert.equal(0, sleepCalls, "Framework-owned ticks do not sleep")
  Assert.equal(0, eventPullCalls, "Framework remains the only event.pull owner")
end
Assert.endTest()

Assert.startTest("ExecBroker defers processing on budget exhaustion but still cleans up")
do
  local broker = newBroker({
    useTimeSliceScheduler = true,
    timeSliceScheduler = {
      reset = function() end,
      remaining = function() return 0 end,
    },
  })
  broker._activeJobs = {
    ["lane-a"] = { phase = ExecBroker.PHASES.PROCESSING },
    ["lane-b"] = { phase = ExecBroker.PHASES.CLEANUP },
  }
  local processingCalls, cleanupCalls = 0, 0
  broker._checkProcessingJob = function()
    processingCalls = processingCalls + 1
  end
  broker._cleanupJob = function()
    cleanupCalls = cleanupCalls + 1
  end

  broker:tick()

  Assert.equal(0, processingCalls, "Processing work waits for the next budget")
  Assert.equal(1, cleanupCalls, "CLEANUP still runs on an exhausted tick")
end
Assert.endTest()

Assert.startTest("ExecBroker retains telemetry matrix entries across budgeted ticks")
do
  local scheduler = {
    reset = function() end,
    remaining = function() return 1 end,
  }
  local broker = newBroker({
    useTimeSliceScheduler = true,
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

  Assert.equal(1, #payloads, "Telemetry is still broadcast with the scheduler enabled")
  Assert.hasKey(payloads[1].machines, "lane-a",
    "Budgeted telemetry includes the first machine entry")
  Assert.hasKey(payloads[1].machines, "lane-b",
    "Budgeted telemetry includes the next machine entry")
end
Assert.endTest()
