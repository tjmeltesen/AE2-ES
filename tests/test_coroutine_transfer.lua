local Assert = require("tests.helpers.assertions")
local ExecBroker = require("src.exec_broker")
local JobManifest = require("src.jobmanifest")
local MockModules = require("tests.helpers.mock_modules")

local function newRegistry()
  local registry = { threads = {} }
  function registry:registerThread(callback)
    local thread = { coroutine = coroutine.create(callback) }
    table.insert(self.threads, thread)
    return thread
  end
  function registry:resumeAll()
    for _, thread in ipairs(self.threads) do
      if coroutine.status(thread.coroutine) ~= "dead" then
        local ok, err = coroutine.resume(thread.coroutine)
        assert(ok, err)
      end
    end
  end
  return registry
end

local function newBroker(options)
  options = options or {}
  local broker = ExecBroker.new({
    brokerId = "coroutine-transfer-test",
    machines = { { laneId = "lane-1", machineAddr = "machine-1" } },
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
    useCoroutineTransfer = options.useCoroutineTransfer == true,
    threadRegistry = options.threadRegistry,
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
  broker._logger = { info = function() end, debug = function() end, warn = function() end }
  return broker
end

local function newActive()
  local manifest = JobManifest.new("coroutine-job", { items = {} })
  manifest:updateState("ALLOCATING")
  return {
    manifest = manifest,
    phase = ExecBroker.PHASES.TRANSFERRING,
    _transferStep = "pull",
    _transferTick = 0,
    _transferDbSlots = { items = { { dbSlot = 1 } } },
  }
end

Assert.startTest("tracked transfer coroutine completes and releases its lane")
do
  local registry = newRegistry()
  local broker = newBroker({ useCoroutineTransfer = true, threadRegistry = registry })
  local active = newActive()
  broker._activeJobs["lane-1"] = active

  broker:_phaseTRANSFERRING()
  Assert.equal(1, #registry.threads, "one framework thread is registered for the lane")
  broker:_phaseTRANSFERRING()
  Assert.equal(1, #registry.threads, "a lane cannot register a second transfer thread")

  registry:resumeAll()
  Assert.equal("verify", active._transferStep, "first coroutine resume performs pull")
  registry:resumeAll()
  Assert.equal("clear", active._transferStep, "second coroutine resume verifies pull")
  registry:resumeAll()
  Assert.equal(ExecBroker.PHASES.PROCESSING, active.phase, "completed coroutine begins processing")
  registry:resumeAll()
  Assert.isNil(active._transferThread, "completed coroutine releases its lane marker")
end
Assert.endTest()

Assert.startTest("transfer timeout faults an unscheduled lane")
do
  local registry = newRegistry()
  local broker = newBroker({ useCoroutineTransfer = true, threadRegistry = registry })
  local active = newActive()
  active._transferStartedAt = 100
  broker._activeJobs["lane-1"] = active
  ExecBroker._clockOverride = function() return 131 end

  broker:_phaseTRANSFERRING()
  ExecBroker._clockOverride = nil
  Assert.equal(ExecBroker.PHASES.CLEANUP, active.phase, "overdue transfer enters cleanup")
  Assert.equal("FAULTED", active.manifest.status, "overdue transfer faults its manifest")
  Assert.equal(0, #registry.threads, "timed-out lane is never scheduled")
end
Assert.endTest()

Assert.startTest("transfer coroutine faults its own lane on crash")
do
  local registry = newRegistry()
  local broker = newBroker({ useCoroutineTransfer = true, threadRegistry = registry })
  local active = newActive()
  broker._activeJobs["lane-1"] = active
  broker._transferForJob = function() error("injected transfer crash") end

  broker:_phaseTRANSFERRING()
  registry:resumeAll()
  Assert.equal(ExecBroker.PHASES.CLEANUP, active.phase, "crashed transfer enters cleanup")
  Assert.equal("FAULTED", active.manifest.status, "crashed transfer faults its manifest")
  Assert.match("crashed", active.manifest.faultReason, "fault records coroutine crash")
end
Assert.endTest()

Assert.startTest("coroutine-disabled transfer uses cooperative fallback")
do
  local registry = newRegistry()
  local broker = newBroker({ useCoroutineTransfer = false, threadRegistry = registry })
  local active = newActive()
  broker._activeJobs["lane-1"] = active

  broker:_phaseTRANSFERRING()
  Assert.equal(0, #registry.threads, "disabled flag does not register a framework thread")
  Assert.equal("verify", active._transferStep, "cooperative tick performs transfer work")
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_coroutine_transfer%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end
