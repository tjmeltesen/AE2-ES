-- Dependency-injection composition for executable AE2-ES programs.
-- This module deliberately constructs OC-bound objects only when asked.

local Config = {}

function Config.loadBroker(path)
  local ConfigUI = require("src.config_ui")
  local ExecBroker = require("src.exec_broker")
  local configUI = ConfigUI.new(path)
  local persisted, err = configUI:loadConfig()
  if not persisted then return nil, err end

  local runtimeConfig = configUI:buildExecConfig()
  if not runtimeConfig then return nil, "could not build broker runtime configuration" end
  return ExecBroker.new(runtimeConfig), nil
end

function Config.loadSupervisor(path)
  local ConfigUI = require("supervisor.config_ui")
  local Supervisor = require("src.supervisor").Supervisor
  local persisted, err = ConfigUI.load_config(path)
  if not persisted then return nil, err end
  return Supervisor.new(persisted), nil
end

return Config
