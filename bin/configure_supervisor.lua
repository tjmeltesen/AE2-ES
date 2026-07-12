-- Explicit configuration launcher for the AE2-ES Supervisor.

local ConfigUI = require("supervisor.config_ui")

local config = ConfigUI.run_config_ui()
if not config then
  error("Configuration cancelled; no supervisor configuration was saved")
end

local saved, err = ConfigUI.save_config(config)
if not saved then
  error("Could not save supervisor configuration: " .. tostring(err))
end

print("Supervisor configuration saved to " .. ConfigUI.get_config_path())
