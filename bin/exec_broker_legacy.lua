-- Legacy blocking broker launcher, retained while the framework flag is off.

local ExecBroker = require("src.exec_broker")
local BrokerLogger = require("src.broker_logger")

local function run(config)
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

  if not ran then error(ok) end
  if ok == false then error("Exec Broker stopped with an error: " .. tostring(err)) end
end

return { run = run }
