-- Production launcher for the canonical AE2-ES Supervisor subscriber.
-- The dashboard is intentionally not composed until real dependencies exist.

local ConfigUI = require("supervisor.config_ui")

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
