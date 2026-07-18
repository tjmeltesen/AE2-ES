local Assert = require("tests.helpers.assertions")

package.path = "./lib/?.lua;" .. package.path

local BoundedList = require("lib.bounded_list")

Assert.startTest("BoundedList: trims oldest entries to its target")
do
  local list = BoundedList.new(4, 2)
  for i = 1, 5 do
    list:push(i)
  end

  local entries = list:toTable()
  Assert.equal(2, list:size(), "overflow retains the trim target")
  Assert.equal(4, entries[1], "oldest retained entry follows the trim")
  Assert.equal(5, entries[2], "newest entry is retained")
end
Assert.endTest()

Assert.startTest("BoundedList: pushFront preserves newest-first insertion")
do
  local list = BoundedList.new(3)
  list:push("second")
  list:pushFront("first")

  local entries = list:toTable()
  Assert.equal(2, list:size(), "front insertion increases size")
  Assert.equal("first", entries[1], "front insertion becomes the first entry")
  Assert.equal("second", entries[2], "existing entries keep their order")
end
Assert.endTest()

Assert.startTest("BoundedList: calculates average and median")
do
  local list = BoundedList.new(10)
  list:push(9)
  list:push(1)
  list:push(5)
  list:push(3)

  Assert.equal(4.5, list:average(), "average includes all numeric entries")
  Assert.equal(4, list:median(), "median averages the two middle sorted entries")
end
Assert.endTest()

Assert.startTest("BoundedList: clear removes every entry")
do
  local list = BoundedList.new(2)
  list:push("entry")

  Assert.equal(1, list:clear(), "clear returns the removed count")
  Assert.equal(0, list:size(), "clear empties the list")
  Assert.tableEmpty(list:toTable(), "clear returns an empty backing table")
end
Assert.endTest()

Assert.startTest("MaintenanceReport: history keeps its existing capacity and order")
do
  local MaintenanceReport = require("src.maintenance_report")
  local report = MaintenanceReport.new("bounded-history")
  report._maxHistory = 3
  for i = 1, 4 do
    report:logToHistory({ code = i, description = "event " .. i })
  end

  local history = report:getHistory()
  Assert.equal(3, #history, "history retains the configured capacity")
  Assert.equal("event 2", history[1].description, "history drops the oldest event")
  Assert.equal("event 4", history[3].description, "history keeps the newest event")
end
Assert.endTest()

Assert.startTest("Supervisor: telemetry and log buffers preserve trim ordering")
do
  package.loaded["component"] = {
    isAvailable = function() return true end,
    modem = {},
  }
  package.loaded["event"] = {}
  package.loaded["computer"] = {
    uptime = function() return 0 end,
  }

  local SupervisorModule = require("src.supervisor")
  local queue = SupervisorModule.TelemetryQueue.new(3, 2)
  for i = 1, 4 do
    queue:push(i)
  end

  Assert.equal(2, queue:count(), "telemetry queue trims to its target")
  Assert.equal(3, queue:pop(), "telemetry queue retains the oldest trimmed entry")
  Assert.equal(4, queue:pop(), "telemetry queue retains the newest entry")
  Assert.equal(2, queue:stats().dropped, "telemetry queue records dropped entries")

  local supervisor = SupervisorModule.Supervisor.new({ maxLogEntries = 2 })
  supervisor:logMessage("INFO", "first")
  supervisor:logMessage("INFO", "second")
  supervisor:logMessage("INFO", "third")
  local log = supervisor:getLog()
  Assert.equal(2, #log, "log retains its configured capacity")
  Assert.equal("second", log[1].message, "log drops the oldest entry")
  Assert.equal("third", log[2].message, "log keeps the newest entry")
end
Assert.endTest()

return true
