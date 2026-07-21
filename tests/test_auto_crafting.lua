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

local function newBroker(options)
  options = options or {}
  local broker = ExecBroker.new({
    brokerId = "auto-crafting-test",
    machines = {},
    modules = modules(),
    enableAutoCrafting = options.enableAutoCrafting == true,
    autoCraftInputs = options.autoCraftInputs or {
      { name = "minecraft:iron_ingot", amount = 64 },
    },
    bufferFeeder = options.bufferFeeder or function()
      return { items = {}, fluids = {} }
    end,
    pollInterval = 0,
    heartbeatInterval = 999,
  })
  broker._logger = { info = function() end, debug = function() end, warn = function() end }
  return broker
end

Assert.startTest("auto-crafting requests only whitelisted deficits every fifth buffer poll")
do
  local broker = newBroker({
    enableAutoCrafting = true,
    autoCraftInputs = {
      { name = "minecraft:iron_ingot", amount = 64 },
    },
    bufferFeeder = function()
      return {
        items = {
          { name = "minecraft:iron_ingot", size = 32 },
          { name = "minecraft:gold_ingot", size = 0 },
        },
        fluids = {},
      }
    end,
  })
  local requests = {}
  broker._hal.requestCraft = function(_, address, filter, amount)
    table.insert(requests, { address = address, name = filter.name, amount = amount })
    return true
  end
  broker._meControllerAddr = "me-controller"

  for _ = 1, 4 do broker:_pollBuffer() end
  Assert.equal(0, #requests, "no request is sent before the fifth buffer poll")

  broker:_pollBuffer()
  Assert.equal(1, #requests, "one whitelisted deficit is requested on the fifth poll")
  if requests[1] then
    Assert.equal("minecraft:iron_ingot", requests[1].name, "only the configured item is requested")
    Assert.equal(32, requests[1].amount, "only the configured deficit is requested")
  end
end
Assert.endTest()

Assert.startTest("auto-crafting opens a per-item circuit after three unfulfilled requests")
do
  local broker = newBroker({ enableAutoCrafting = true })
  local requests = 0
  broker._hal.requestCraft = function()
    requests = requests + 1
    return true
  end
  broker._meControllerAddr = "me-controller"

  for _ = 1, 20 do broker:_pollBuffer() end

  Assert.equal(3, requests, "the fourth unfulfilled request is blocked")
  Assert.isTrue((broker._autoCraftCircuits or {})["minecraft:iron_ingot"],
    "the circuit is open for the unavailable item")
end
Assert.endTest()

Assert.startTest("auto-crafting resets an open circuit when stock arrives")
do
  local available = false
  local broker = newBroker({
    enableAutoCrafting = true,
    bufferFeeder = function()
      return {
        items = available and { { name = "minecraft:iron_ingot", size = 64 } } or {},
        fluids = {},
      }
    end,
  })
  local requests = 0
  broker._hal.requestCraft = function()
    requests = requests + 1
    return true
  end
  broker._meControllerAddr = "me-controller"

  for _ = 1, 15 do broker:_pollBuffer() end
  Assert.isTrue((broker._autoCraftCircuits or {})["minecraft:iron_ingot"],
    "the circuit opens after three missed deliveries")

  available = true
  for _ = 1, 5 do broker:_pollBuffer() end
  Assert.isNil((broker._autoCraftCircuits or {})["minecraft:iron_ingot"],
    "arriving stock closes the circuit")

  available = false
  for _ = 1, 5 do broker:_pollBuffer() end
  Assert.equal(4, requests, "a newly missing item can be requested after reset")
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_auto_crafting%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end

return true
