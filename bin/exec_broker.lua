-- Production launcher for the AE2-ES Exec Broker.

local ConfigUI = require("src.config_ui")

local function buildControlHandler(config, broker)
  if config.enableRemoteControl ~= true then return nil end

  local component = require("component")
  local digest = component.data and component.data.sha256
  local Orchestrator = require("supervisor.orchestrator")
  return Orchestrator.new({
    id = tostring(config.brokerId),
    enabled = true,
    controlPort = config.controlPort or 124,
    secret = config.controlAuthSecret,
    digest = digest,
    log = function(level, message)
      if broker._logger and broker._logger.warn then broker._logger:warn(message) end
    end,
    onThrottle = function(interval) return broker:setPollInterval(interval) end,
    onRestart = function()
      broker:stop()
      local computer = require("computer")
      computer.shutdown(true)
    end,
    allowThrottle = config.enableRemoteThrottle == true,
    allowRestart = config.enableRemoteRestart == true,
  })
end

local configUI = ConfigUI.new()
local config, loadErr = configUI:loadConfig()

if not config then
  print("Broker configuration unavailable (" .. tostring(loadErr) .. ").")
  print("Starting configuration UI...")
  config = configUI:run()
  if not config then
    error("Configuration cancelled; Exec Broker was not started")
  end

  local saved, saveErr = configUI:saveConfig(config)
  if not saved then
    error("Could not save broker configuration: " .. tostring(saveErr))
  end
end

print("Starting Exec Broker: " .. tostring(config.brokerId))
if config.useProgramFramework ~= true then
  require("bin.exec_broker_legacy").run(configUI:buildExecConfig())
else
  local ProgramFramework = require("lib.program_framework")
  local Config = require("config")
  local BrokerLogger = require("src.broker_logger")
  local broker, err = Config.loadBroker(configUI._configPath)
  if not broker then error("Could not construct Exec Broker: " .. tostring(err)) end

  local framework = ProgramFramework.new({ pollInterval = config.pollInterval })
  local controlHandler = buildControlHandler(config, broker)
  if controlHandler then broker:setControlHandler(controlHandler) end
  if config.useCoroutineTransfer == true then
    broker:setThreadRegistry(framework)
  end
  if config.enableDiscovery == true then
    framework:registerTimer(30, function()
      local refreshed, err = broker:refreshMachines()
      if not refreshed and broker._logger then
        broker._logger:warn("Machine discovery refresh failed: " .. tostring(err))
      end
    end)
  end
  framework:registerInit(function()
    local event = require("event")
    local logger = BrokerLogger.new(tostring(config.brokerId) .. ":events")
    return logger:attachEventListeners(event)
  end)
  if controlHandler then
    framework:registerInit(function()
      if not config.modem then error("Remote control requires a configured modem") end
      local ok, openErr = pcall(config.modem.open, config.controlPort or 124)
      if not ok then error("Could not open control port: " .. tostring(openErr)) end
      controlHandler:setModem(config.modem)
      return function() pcall(config.modem.close, config.controlPort or 124) end
    end)
  end
  framework:registerLoop(function(signal)
    if signal[1] == "interrupted" then return false end
    if controlHandler and signal[1] == "modem_message" then
      controlHandler:handle(signal[3], signal[4], signal[6])
    end
    return broker:tick()
  end)
  framework:registerShutdown(function() broker:stop() end)

  local ok, frameworkErr = framework:start()
  if not ok then error("Exec Broker stopped with an error: " .. tostring(frameworkErr)) end
end
