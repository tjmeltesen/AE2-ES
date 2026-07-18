local Assert = require("tests.helpers.assertions")
local ExecBroker = require("src.exec_broker")
local JobManifest = require("src.jobmanifest")
local MockModules = require("tests.helpers.mock_modules")

local function newBroker()
  local broker = ExecBroker.new({
    brokerId = "transfer-retry-test",
    machines = {
      { laneId = "lane-1", machineAddr = "machine-1" },
    },
    machineTransposers = {
      ["lane-1"] = {
        dualInterface = "interface-1",
        transposerAddr = "transposer-1",
        pull = 1,
        push = 2,
        return_ = 3,
      },
    },
    databaseAddr = "database-1",
    modules = {
      JobManifest = JobManifest,
      MachineNode = MockModules.MachineNode,
      BufferSnapshot = { new = function() return {} end },
      JobQueue = MockModules.JobQueue,
      HAL = MockModules.HAL,
      MaintenanceReport = MockModules.MaintenanceReport,
      TelemetryPayload = require("src.telemetrypayload"),
    },
  })
  broker._logger = {
    info = function() end,
    debug = function() end,
    warnings = {},
    warn = function(self, message)
      table.insert(self.warnings, message)
    end,
  }
  return broker
end

local function newActive()
  local manifest = JobManifest.new("transfer-job", { items = {} })
  manifest:updateState("ALLOCATING")
  return {
    manifest = manifest,
    phase = ExecBroker.PHASES.TRANSFERRING,
    _transferStep = "pull",
    _transferTick = 0,
    _transferDbSlots = {
      items = {
        { dbSlot = 1 },
        { dbSlot = 2, fluidDrop = true, fluidSide = 0 },
      },
    },
  }
end

Assert.startTest("dry pulls retry on later broker ticks then fault")
do
  local broker = newBroker()
  local active = newActive()
  local hal = broker:getHAL()
  hal.drainInventory = function(self)
    self._drainLog[#self._drainLog + 1] = { dry = true }
    return 0
  end

  broker:_transferForJob("lane-1", active)
  Assert.equal("pull", active._transferStep, "first dry pull retains pull step")
  Assert.equal(1, active._transferAttempts, "first dry pull records attempt")
  Assert.equal(ExecBroker.PHASES.TRANSFERRING, active.phase, "job remains transferring")

  broker:_transferForJob("lane-1", active)
  Assert.equal("pull", active._transferStep, "second dry pull retains pull step")
  Assert.equal(2, active._transferAttempts, "second dry pull records attempt")

  broker:_transferForJob("lane-1", active)
  Assert.equal(ExecBroker.PHASES.CLEANUP, active.phase, "third dry pull faults to cleanup")
  Assert.equal("FAULTED", active.manifest.status, "manifest is faulted after three attempts")
  Assert.equal(1, #broker._logger.warnings, "fault emits a warning")
  Assert.match("3 attempts", broker._logger.warnings[1], "warning includes attempt count")
end
Assert.endTest()

Assert.startTest("successful pull clears item and fluid transfer state")
do
  local broker = newBroker()
  local active = newActive()

  broker:_transferForJob("lane-1", active)
  Assert.equal("verify", active._transferStep, "successful pull advances to verify")
  Assert.equal(nil, active._transferAttempts, "successful pull does not retain attempts")

  broker:_transferForJob("lane-1", active)
  Assert.equal("clear", active._transferStep, "verified pull advances to clear")

  broker:_transferForJob("lane-1", active)
  local hal = broker:getHAL()
  Assert.equal(1, #hal._clearedIfaces, "item interface slot is cleared")
  Assert.equal(1, #hal._fluidClears, "fluid export is cleared")
  Assert.equal(2, #hal._clearedSlots, "database slots are cleared")
  Assert.equal(ExecBroker.PHASES.PROCESSING, active.phase, "successful transfer begins processing")
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_transfer_clear_and_fluids%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end
