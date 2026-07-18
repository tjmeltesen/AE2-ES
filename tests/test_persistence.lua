local Assert = require("tests.helpers.assertions")
local Persistence = require("lib.persistence")
local ExecBroker = require("src.exec_broker")
local JobManifest = require("src.jobmanifest")
local JobQueue = require("src.job_queue")
local MaintenanceReport = require("src.maintenance_report")
local TelemetryPayload = require("src.telemetrypayload")
local MockModules = require("tests.helpers.mock_modules")

local function newStore(prefix)
  return Persistence.new({ directory = ".", prefix = prefix })
end

local function modules()
  return {
    JobManifest = JobManifest,
    JobQueue = JobQueue,
    MaintenanceReport = MaintenanceReport,
    MachineNode = MockModules.MachineNode,
    BufferSnapshot = MockModules.BufferSnapshot,
    HAL = MockModules.HAL,
    TelemetryPayload = TelemetryPayload,
  }
end

local function componentApi(address)
  return {
    list = function()
      local emitted = false
      return function()
        if emitted then return nil end
        emitted = true
        return address, "gt_machine"
      end
    end,
    proxy = function()
      return { getMachineName = function() return "stable-lane" end }
    end,
  }
end

local function broker(store, address)
  local result = ExecBroker.new({
    brokerId = "persistence-test",
    machines = {},
    modules = modules(),
    enablePersistence = true,
    persistence = store,
    persistenceKey = "broker",
    enableDiscovery = true,
    componentApi = componentApi(address),
    minMachines = 1,
  })
  result._logger = { warn = function() end, info = function() end, debug = function() end }
  return result
end

Assert.startTest("persistence writes through a temporary file before rename")
do
  os.remove("./.persistence-atomic-atomic.lua")
  os.remove("./.persistence-atomic-atomic.lua.tmp")
  local renamed = {}
  local store = Persistence.new({
    directory = ".",
    prefix = ".persistence-atomic-",
    rename = function(source, destination)
      renamed.source, renamed.destination = source, destination
      return os.rename(source, destination)
    end,
  })
  Assert.isTrue(store:save("atomic", { schemaVersion = 1, writtenAt = 1, payload = {} }))
  Assert.match("%.tmp$", renamed.source, "rename source is the temporary file")
  Assert.match("atomic%.lua$", renamed.destination, "rename destination is the final file")
  Assert.isNil(io.open(renamed.source, "r"), "temporary file is gone after rename")
  store:remove("atomic")
end
Assert.endTest()

Assert.startTest("corrupt and incompatible persistence is discarded")
do
  local store = newStore(".persistence-invalid-")
  local path = "./.persistence-invalid-corrupt.lua"
  local file = assert(io.open(path, "w"))
  file:write("not valid lua")
  file:close()
  local value, err = store:load("corrupt", function() return true end)
  Assert.isNil(value)
  Assert.match("corrupt", err)
  Assert.isNil(io.open(path, "r"), "corrupt file is removed")

  Assert.isTrue(store:save("mismatch", { schemaVersion = 2, writtenAt = 1, payload = {} }))
  value, err = store:load("mismatch", function(envelope) return envelope.schemaVersion == 1, "schema mismatch" end)
  Assert.isNil(value)
  Assert.match("incompatible", err)
  Assert.isNil(io.open("./.persistence-invalid-mismatch.lua", "r"), "mismatched file is removed")
end
Assert.endTest()

Assert.startTest("mid-transfer jobs recover only through the pending queue")
do
  local store = newStore(".persistence-recovery-")
  local first = broker(store, "old-address")
  local job = JobManifest.new("transfer-job", { ["minecraft:iron_ingot"] = 4 })
  job.status, job.state, job.assignedMachine = "TRANSFERRING", "TRANSFERRING", "old-address"
  first._activeJobs["stable-lane"] = {
    manifest = job,
    phase = ExecBroker.PHASES.TRANSFERRING,
    assignedAt = os.time(),
  }
  Assert.isTrue(first:_savePersistence())

  local restored = broker(store, "new-address")
  Assert.equal(0, restored:_countActiveJobs(), "in-flight state is never restored")
  Assert.equal(1, restored:getQueue():length(), "interrupted job is queued for retry")
  Assert.equal("PENDING", restored:getQueue():toPersistence()[1].status,
    "recovered job has no in-flight transfer state")
  local recovered = restored:getQueue():popNextAvailable()
  Assert.equal(nil, recovered.assignedMachine, "old hardware binding is discarded")
  Assert.isTrue(recovered.metadata.persistenceRecovery.retryable)
  store:remove("broker")
end
Assert.endTest()

Assert.startTest("discovery rebinds addresses while restoring maintenance history")
do
  local store = newStore(".persistence-rebind-")
  local first = broker(store, "old-address")
  first:getReport("stable-lane"):reportAdvisory(12, "saved history")
  Assert.isTrue(first:_savePersistence())

  local restored = broker(store, "new-address")
  Assert.equal("new-address", restored:getMachine("stable-lane").hardwareAddress,
    "stable machine identity resolves to its newly discovered address")
  Assert.equal(1, #restored:getReport("stable-lane"):getHistory(),
    "maintenance history follows the stable lane")
  store:remove("broker")
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_persistence%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end

return true
