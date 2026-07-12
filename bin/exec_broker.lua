-- Production launcher for the AE2-ES Exec Broker.

local ConfigUI = require("src.config_ui")
local ExecBroker = require("src.exec_broker")

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
local ok, err = ExecBroker.new(config):run()
if ok == false then
  error("Exec Broker stopped with an error: " .. tostring(err))
end
