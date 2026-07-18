-- Legacy blocking supervisor launcher, retained while the framework flag is off.

local Supervisor = require("src.supervisor").Supervisor

local function buildControlHandler(config, supervisor)
  if config.enableRemoteControl ~= true then return nil end
  local component = require("component")
  local Orchestrator = require("supervisor.orchestrator")
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

local function run(config)
  local supervisor = Supervisor.new(config)
  local controlHandler = buildControlHandler(config, supervisor)
  if controlHandler then supervisor:setControlHandler(controlHandler) end
  local ok, err = supervisor:start()
  if ok == false then error("Supervisor stopped with an error: " .. tostring(err)) end
end

return { run = run }
