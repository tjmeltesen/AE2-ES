-- Production launcher for the canonical AE2-ES Supervisor subscriber.
-- The dashboard is intentionally not composed until real dependencies exist.

local ConfigUI = require("supervisor.config_ui")

local function buildControlHandler(config, supervisor)
  if config.enableRemoteControl ~= true then return nil end
  local component = require("component")
  local Orchestrator = require("lib.orchestrator")
  return Orchestrator.new({
    id = config.supervisorId or "supervisor",
    enabled = true,
    controlPort = config.controlPort or 124,
    secret = config.controlAuthSecret,
    digest = component.data and component.data.sha256,
    log = function(level, message) supervisor:logMessage(level, message) end,
    onPong = function(message)
      supervisor:logMessage("INFO", "PONG received from " .. message.senderId)
    end,
  })
end

local config, loadErr = ConfigUI.load_config()
if not config then
  print("Supervisor configuration unavailable (" .. tostring(loadErr) .. ").")
  print("Starting configuration UI...")
  config = ConfigUI.run_config_ui()
  if not config then
    error("Configuration cancelled; Supervisor was not started")
  end

  local saved, saveErr = ConfigUI.save_config(config)
  if not saved then
    error("Could not save supervisor configuration: " .. tostring(saveErr))
  end
end

print("Starting Supervisor on port " .. tostring(config.supervisorPort))
if config.useProgramFramework ~= true then
  require("bin.supervisor_legacy").run(config)
else
  local ProgramFramework = require("lib.program_framework")
  local Config = require("config")
  local supervisor, err = Config.loadSupervisor()
  if not supervisor then error("Could not construct Supervisor: " .. tostring(err)) end
  local controlHandler = buildControlHandler(config, supervisor)
  if controlHandler then supervisor:setControlHandler(controlHandler) end

  local framework = ProgramFramework.new()
  framework:registerInit(function()
    local initialized, initErr = supervisor:initialize()
    if not initialized then error(initErr) end
  end)
  framework:registerTimer(config.healthCheckInterval or 5, function()
    supervisor:_healthCheck()
  end)
  framework:registerLoop(function(signal)
    return supervisor:handleEvent(signal)
  end)
  framework:registerShutdown(function() supervisor:shutdown() end)

  local ok, frameworkErr = framework:start()
  if not ok then error("Supervisor stopped with an error: " .. tostring(frameworkErr)) end
end
