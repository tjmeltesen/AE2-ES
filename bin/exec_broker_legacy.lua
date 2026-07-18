-- Legacy blocking broker launcher, retained while the framework flag is off.

local ExecBroker = require("src.exec_broker")
local BrokerLogger = require("src.broker_logger")

local function attachControl(config, broker)
  if config.enableRemoteControl ~= true then return function() end end
  if not config.modem then error("Remote control requires a configured modem") end
  local component = require("component")
  local Orchestrator = require("supervisor.orchestrator")
  local control = Orchestrator.new({
    id = tostring(config.brokerId),
    enabled = true,
    controlPort = config.controlPort or 124,
    secret = config.controlAuthSecret,
    digest = component.data and component.data.sha256,
    modem = config.modem,
    log = function(_, message)
      if broker._logger and broker._logger.warn then broker._logger:warn(message) end
    end,
    onThrottle = function(interval) return broker:setPollInterval(interval) end,
    onRestart = function()
      broker:stop()
      require("computer").shutdown(true)
    end,
    allowThrottle = config.enableRemoteThrottle == true,
    allowRestart = config.enableRemoteRestart == true,
  })
  broker:setControlHandler(control)
  local ok, err = pcall(config.modem.open, config.controlPort or 124)
  if not ok then error("Could not open control port: " .. tostring(err)) end
  return function() pcall(config.modem.close, config.controlPort or 124) end
end

local function run(config)
  local broker = ExecBroker.new(config)
  local closeControl = attachControl(config, broker)
  local cleanupListeners = function() end
  local eventOk, eventApi = pcall(require, "event")
  if eventOk then
    local eventLogger = BrokerLogger.new(tostring(config.brokerId) .. ":events")
    cleanupListeners = eventLogger:attachEventListeners(eventApi)
  end

  local ran, ok, err = xpcall(function()
    return broker:run()
  end, function(runErr)
    return tostring(runErr)
  end)
  cleanupListeners()
  closeControl()

  if not ran then error(ok) end
  if ok == false then error("Exec Broker stopped with an error: " .. tostring(err)) end
end

return { run = run }
