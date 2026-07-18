local Assert = require("tests.helpers.assertions")
local MaintenanceReport = require("src.maintenance_report")
local BrokerLogger = require("src.broker_logger")

local function newEventBus()
  local listeners = {}
  local event = { listenCount = 0, ignoreCount = 0, pushes = {} }

  function event.listen(name, callback)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], callback)
    event.listenCount = event.listenCount + 1
  end

  function event.ignore(name, callback)
    local callbacks = listeners[name] or {}
    for index, registered in ipairs(callbacks) do
      if registered == callback then
        table.remove(callbacks, index)
        event.ignoreCount = event.ignoreCount + 1
        return true
      end
    end
    return false
  end

  function event.push(name, payload)
    table.insert(event.pushes, { name = name, payload = payload })
    for _, callback in ipairs(listeners[name] or {}) do
      callback(name, payload)
    end
  end

  return event
end

Assert.startTest("BrokerLogger: attaches namespaced listeners and cleans them up")
do
  local event = newEventBus()
  local logger = BrokerLogger.new("collector")
  local cleanup = logger:attachEventListeners(event)

  Assert.type("function", cleanup, "attach returns cleanup callback")
  Assert.equal(3, event.listenCount, "one listener is registered per severity event")

  event.push("ae2es:log_warning", {
    originId = "machine-a",
    message = "input blocked",
    jobId = "job-1",
  })

  local entries = logger:getRecent(10)
  Assert.equal(1, #entries, "warning event is stored directly")
  Assert.equal("WARN", entries[1].severity, "warning event maps to WARN")
  Assert.equal("machine-a", entries[1].originId, "event origin is preserved")
  Assert.equal("job-1", entries[1].jobId, "event job id is preserved")

  cleanup()
  Assert.equal(3, event.ignoreCount, "cleanup unregisters every listener")
  event.push("ae2es:log_error", { originId = "machine-a", message = "ignored" })
  Assert.equal(1, #logger:getRecent(10), "cleaned-up listeners do not receive events")
end
Assert.endTest()

Assert.startTest("BrokerLogger: publishes direct logs with namespaced severity events")
do
  local event = newEventBus()
  local producer = BrokerLogger.new("broker-a")
  local collector = BrokerLogger.new("collector")
  collector:attachEventListeners(event)

  local previousEvent = rawget(_G, "event")
  _G.event = event
  producer:info("started")
  producer:warn("slow")
  producer:error("failed")
  producer:critical("offline")
  _G.event = previousEvent

  Assert.equal("ae2es:log_info", event.pushes[1].name, "INFO maps to log_info")
  Assert.equal("ae2es:log_warning", event.pushes[2].name, "WARN maps to log_warning")
  Assert.equal("ae2es:log_error", event.pushes[3].name, "ERROR maps to log_error")
  Assert.equal("ae2es:log_error", event.pushes[4].name, "CRITICAL maps to log_error")
  Assert.equal(4, #collector:getRecent(10), "collector receives each published log")
end
Assert.endTest()

Assert.startTest("MaintenanceReport: records history before publishing namespaced faults")
do
  local event = newEventBus()
  local collector = BrokerLogger.new("collector")
  collector:attachEventListeners(event)

  local previousEvent = rawget(_G, "event")
  _G.event = event
  local report = MaintenanceReport.new("machine-b")
  report:reportFault(2, "input blocked")
  report:reportFault(1, "power lost")
  report:clearFault("power restored")
  _G.event = previousEvent

  local history = report:getHistory()
  Assert.equal(3, #history, "all maintenance events remain in history")
  Assert.equal("ae2es:log_warning", event.pushes[1].name, "warning faults publish warning events")
  Assert.equal("ae2es:log_error", event.pushes[2].name, "critical faults publish error events")
  Assert.equal("ae2es:log_info", event.pushes[3].name, "fault clears publish info events")
  Assert.equal(3, #collector:getRecent(10), "collector receives maintenance events")
end
Assert.endTest()

Assert.startTest("MaintenanceReport: retains history when event publication fails")
do
  local previousEvent = rawget(_G, "event")
  _G.event = {
    push = function()
      error("event queue unavailable")
    end,
  }

  local report = MaintenanceReport.new("machine-c")
  local ok = pcall(report.reportFault, report, 7, "offline")
  _G.event = previousEvent

  Assert.isTrue(ok, "publication errors do not escape")
  Assert.equal(1, #report:getHistory(), "history is recorded despite publication failure")
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_pubsub_logging%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end

return true
