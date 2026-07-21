local Assert = require("tests.helpers.assertions")
local ExecBroker = require("src.exec_broker")
local MockModules = require("tests.helpers.mock_modules")

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

local function componentApi(entries, names)
  return {
    list = function()
      local index = 0
      return function()
        index = index + 1
        local entry = entries[index]
        if entry then return entry.address, entry.type end
      end
    end,
    proxy = function(address)
      return {
        getMachineName = function()
          return names[address]
        end,
      }
    end,
  }
end

local function newBroker(options)
  options = options or {}
  local broker = ExecBroker.new({
    brokerId = "machine-discovery-test",
    machines = options.machines or {},
    modules = modules(),
    enableDiscovery = options.enableDiscovery == true,
    minMachines = options.minMachines,
    componentApi = options.componentApi,
  })
  broker._logger = { info = function() end, debug = function() end, warn = function() end }
  return broker
end

Assert.startTest("discovery merges new machines by stable name and preserves static entries")
do
  local component = componentApi({
    { address = "dynamic-address", type = "gt_machine" },
    { address = "replacement-address", type = "gt_machine" },
  }, {
    ["dynamic-address"] = "dynamic-machine",
    ["replacement-address"] = "static-machine",
  })
  local broker = newBroker({
    enableDiscovery = true,
    minMachines = 2,
    componentApi = component,
    machines = {
      { laneId = "static-lane", machineAddr = "static-address", machineName = "static-machine" },
    },
  })

  Assert.equal("static-address", broker:getMachine("static-lane").hardwareAddress,
    "static configuration wins a stable-name conflict")
  Assert.equal("dynamic-address", broker:getMachine("dynamic-machine").hardwareAddress,
    "a newly discovered stable name is registered")
end
Assert.endTest()

Assert.startTest("discovery invalidates proxy caches and removes vanished dynamic machines")
do
  local entries = { { address = "dynamic-address", type = "gt_machine" } }
  local component = componentApi(entries, { ["dynamic-address"] = "dynamic-machine" })
  local broker = newBroker({
    enableDiscovery = true,
    minMachines = 1,
    componentApi = component,
  })
  local invalidated = {}
  broker._hal.invalidateCache = function(_, address)
    table.insert(invalidated, address)
  end

  entries[1] = nil
  broker:refreshMachines()

  Assert.isNil(broker:getMachine("dynamic-machine"),
    "a vanished discovered machine is removed when no job owns its lane")
  Assert.equal("dynamic-address", invalidated[1],
    "refresh invalidates the departed machine proxy")
end
Assert.endTest()

Assert.startTest("discovery is opt-in and startup rejects an undersized machine set")
do
  local called = false
  local component = {
    list = function()
      called = true
      return function() end
    end,
  }
  local broker = newBroker({
    enableDiscovery = false,
    componentApi = component,
    machines = { { laneId = "static-lane", machineAddr = "static-address" } },
  })
  Assert.isFalse(called, "flags-off compatibility path never probes components")
  Assert.equal("static-address", broker:getMachine("static-lane").hardwareAddress)

  local ok, err = pcall(newBroker, {
    enableDiscovery = true,
    minMachines = 1,
    componentApi = component,
  })
  Assert.isFalse(ok, "startup rejects fewer than minMachines")
  Assert.match("minMachines", err)
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_machine_discovery%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end

return true
