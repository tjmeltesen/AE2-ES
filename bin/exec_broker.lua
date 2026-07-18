-- Production launcher for the AE2-ES Exec Broker.

local ConfigUI = require("src.config_ui")
local ExecBroker = require("src.exec_broker")
local BrokerLogger = require("src.broker_logger")

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
local broker = ExecBroker.new(config)
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

if not ran then
  error(ok)
end
if ok == false then
  error("Exec Broker stopped with an error: " .. tostring(err))
end
