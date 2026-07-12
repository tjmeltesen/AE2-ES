-- Production launcher for the canonical AE2-ES Supervisor subscriber.
-- The dashboard is intentionally not composed until real dependencies exist.

local ConfigUI = require("supervisor.config_ui")
local Supervisor = require("src.supervisor").Supervisor

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
local ok, err = Supervisor.new(config):start()
if ok == false then
  error("Supervisor stopped with an error: " .. tostring(err))
end
