-- Explicit configuration launcher for the AE2-ES Exec Broker.

local ConfigUI = require("src.config_ui")

local configUI = ConfigUI.new()
local config = configUI:run()
if not config then
  error("Configuration cancelled; no broker configuration was saved")
end

local saved, err = configUI:saveConfig(config)
if not saved then
  error("Could not save broker configuration: " .. tostring(err))
end

print("Broker configuration saved to " .. ConfigUI.CONFIG_PATH)
