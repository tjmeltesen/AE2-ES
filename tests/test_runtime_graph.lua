-- Canonical runtime graph regression tests.
-- Production modules must be safe to require; executable behavior belongs in bin/.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")

MockEnv.setup()

local mockNow = 100
local mockComputer = {
  uptime = function() return mockNow end,
  pushSignal = function() end,
}
local mockEvent = {
  pull = function() return "interrupted" end,
  timer = function() return 1 end,
  cancel = function() end,
}
local mockComponent = {
  isAvailable = function() return true end,
  modem = {
    open = function() return true end,
    close = function() return true end,
  },
}

package.loaded["computer"] = mockComputer
package.loaded["event"] = mockEvent
package.loaded["component"] = mockComponent
package.loaded["serialization"] = MockEnv.serialization
_G.computer = mockComputer
_G.event = mockEvent
_G.component = mockComponent
_G.serialization = MockEnv.serialization

local function restoreLoaded(name, previous)
  package.loaded[name] = previous
end

Assert.startTest("requiring src.exec_broker does not launch configuration")
do
  local previousBroker = package.loaded["src.exec_broker"]
  local previousConfig = package.loaded["src.config_ui"]
  local launches = 0

  package.loaded["src.exec_broker"] = nil
  package.loaded["src.config_ui"] = {
    new = function()
      return {
        run = function()
          launches = launches + 1
          return nil
        end,
      }
    end,
  }

  local ok, module = pcall(require, "src.exec_broker")
  Assert.isTrue(ok, "exec broker module loads")
  Assert.type("table", module, "exec broker exports a module table")
  Assert.equal(0, launches, "require must not run broker config UI")

  restoreLoaded("src.exec_broker", previousBroker)
  restoreLoaded("src.config_ui", previousConfig)
end
Assert.endTest()

Assert.startTest("requiring src.supervisor does not launch configuration")
do
  local previousSupervisor = package.loaded["src.supervisor"]
  local previousConfig = package.loaded["supervisor.config_ui"]
  local launches = 0

  package.loaded["src.supervisor"] = nil
  package.loaded["supervisor.config_ui"] = {
    run_wizard = function()
      launches = launches + 1
      return nil
    end,
    save_config = function() end,
  }

  local ok, module = pcall(require, "src.supervisor")
  Assert.isTrue(ok, "supervisor module loads")
  Assert.type("table", module, "supervisor exports a module table")
  Assert.equal(0, launches, "require must not run supervisor config UI")

  restoreLoaded("src.supervisor", previousSupervisor)
  restoreLoaded("supervisor.config_ui", previousConfig)
end
Assert.endTest()

Assert.startTest("requiring broker config module does not read input")
do
  local previous = package.loaded["src.config_ui"]
  local originalRead = io.read
  local originalWrite = io.write
  local reads = 0

  io.read = function()
    reads = reads + 1
    return "n"
  end
  package.loaded["src.config_ui"] = nil

  local ok, module = pcall(require, "src.config_ui")
  Assert.isTrue(ok, "broker config module loads")
  Assert.type("table", module, "broker config exports a module table")
  Assert.equal(0, reads, "require must not read interactive input")

  io.read = originalRead
  io.write = originalWrite
  restoreLoaded("src.config_ui", previous)
end
Assert.endTest()

Assert.startTest("requiring supervisor config module does not print entrypoint errors")
do
  local previous = package.loaded["supervisor.config_ui"]
  local originalPrint = print
  local printed = 0

  print = function()
    printed = printed + 1
  end
  package.loaded["supervisor.config_ui"] = nil

  local ok, module = pcall(require, "supervisor.config_ui")

  print = originalPrint
  Assert.isTrue(ok, "supervisor config module loads")
  Assert.type("table", module, "supervisor config exports a module table")
  Assert.equal(0, printed, "require must not execute or report a launcher")

  restoreLoaded("supervisor.config_ui", previous)
end
Assert.endTest()

Assert.startTest("all explicit launchers compile")
do
  local launchers = {
    "bin/exec_broker.lua",
    "bin/supervisor.lua",
    "bin/configure_broker.lua",
    "bin/configure_supervisor.lua",
  }

  for _, path in ipairs(launchers) do
    local chunk, err = loadfile(path)
    Assert.type("function", chunk, path .. " compiles: " .. tostring(err))
  end
end
Assert.endTest()

Assert.startTest("canonical supervisor exposes dashboard subscriber interface")
do
  package.loaded["src.supervisor"] = nil
  local SupervisorModule = require("src.supervisor")
  local supervisor = SupervisorModule.Supervisor.new({
    supervisorPort = 100,
    staleThreshold = 30,
    offlineThreshold = 120,
  })

  local payload = MockEnv.serialization.serialize({
    brokerId = "broker-alpha",
    timestamp = mockNow,
    queueLength = 1,
    hardwareMatrix = {},
    alerts = {},
  })

  supervisor:_processMessage("modem-alpha", 100, payload)

  Assert.type("function", supervisor.getQueueSize, "canonical subscriber reports queue size")
  Assert.type("function", supervisor.getBrokerStatus, "canonical subscriber reports broker health")
  Assert.type("function", supervisor.getNextPayload, "canonical subscriber dequeues payload")
  Assert.type("function", supervisor.getActiveBrokers, "canonical subscriber exposes broker map")

  if type(supervisor.getQueueSize) == "function"
      and type(supervisor.getBrokerStatus) == "function"
      and type(supervisor.getNextPayload) == "function"
      and type(supervisor.getActiveBrokers) == "function" then
    Assert.equal(1, supervisor:getQueueSize(), "canonical subscriber reports queue size")
    Assert.equal("ACTIVE", supervisor:getBrokerStatus("broker-alpha"), "new broker is active")
    Assert.equal("broker-alpha", supervisor:getNextPayload().brokerId, "canonical subscriber dequeues payload")

    mockNow = 131
    Assert.equal("STALE", supervisor:getBrokerStatus("broker-alpha"), "broker becomes stale")
    mockNow = 221
    Assert.equal("OFFLINE", supervisor:getBrokerStatus("broker-alpha"), "broker becomes offline")
    Assert.equal("OFFLINE", supervisor:getActiveBrokers()["broker-alpha"].status,
      "active broker map reports computed health")
  end
end
Assert.endTest()

Assert.startTest("canonical supervisor calls modem proxy methods without self")
do
  local openedPort = nil
  local closedPort = nil
  mockComponent.modem.open = function(port)
    openedPort = port
    return true
  end
  mockComponent.modem.close = function(port)
    closedPort = port
    return true
  end

  package.loaded["src.supervisor"] = nil
  local SupervisorModule = require("src.supervisor")
  local supervisor = SupervisorModule.Supervisor.new({ supervisorPort = 321 })
  local ok, err = supervisor:_initModem()

  Assert.isTrue(ok, "modem initializes: " .. tostring(err))
  Assert.equal(321, openedPort, "open receives the port as its first argument")
  supervisor:_closeModem()
  Assert.equal(321, closedPort, "close receives the port as its first argument")
end
Assert.endTest()

Assert.startTest("root domain shims expose canonical module contracts")
do
  local pairsToCheck = {
    { "JobManifest", "src.jobmanifest", { "new" } },
    { "JobQueue", "src.job_queue", { "new" } },
    { "MaintenanceReport", "src.maintenance_report", { "new" } },
  }

  for _, item in ipairs(pairsToCheck) do
    local shim = require(item[1])
    local canonical = require(item[2])
    Assert.equal(canonical, shim, item[1] .. " returns the canonical module")
    for _, method in ipairs(item[3]) do
      Assert.type("function", shim[method], item[1] .. " retains " .. method)
    end
  end
end
Assert.endTest()

Assert.startTest("broker default module map uses canonical domains")
do
  local ExecBroker = require("src.exec_broker")
  local defaults = ExecBroker.DEFAULT_MODULES
  Assert.equal(require("src.jobmanifest"), defaults.JobManifest(), "loads canonical JobManifest")
  Assert.equal(require("src.job_queue"), defaults.JobQueue(), "loads canonical JobQueue")
  Assert.equal(require("src.maintenance_report"), defaults.MaintenanceReport(),
    "loads canonical MaintenanceReport")
end
Assert.endTest()

return true
