local Assert = require("tests.helpers.assertions")
local ProgramFramework = require("lib.program_framework")

local function newEvent()
  local event = { pulls = {}, timers = {}, cancelled = {} }
  function event.pull(timeout)
    table.insert(event.pulls, timeout)
    return "interrupted"
  end
  function event.timer(interval, callback, count)
    local handle = { interval = interval, callback = callback, count = count }
    table.insert(event.timers, handle)
    return handle
  end
  function event.cancel(handle)
    table.insert(event.cancelled, handle)
  end
  return event
end

Assert.startTest("ProgramFramework drives loops and cleans up in reverse order")
do
  local event = newEvent()
  local framework = ProgramFramework.new({ event = event, pollInterval = 0.25 })
  local calls = {}
  framework:registerInit(function()
    table.insert(calls, "init")
    return function() table.insert(calls, "listener-cleanup") end
  end)
  framework:registerLoop(function(signal)
    table.insert(calls, "loop:" .. signal[1])
    return false
  end)
  framework:registerTimer(5, function() end)
  framework:registerShutdown(function() table.insert(calls, "shutdown-1") end)
  framework:registerShutdown(function() table.insert(calls, "shutdown-2") end)

  Assert.isTrue(framework:start(), "framework should finish cleanly")
  Assert.equal(0.25, event.pulls[1], "framework should own event.pull timeout")
  Assert.equal(1, #event.cancelled, "framework should cancel registered timers")
  Assert.equal("init", calls[1])
  Assert.equal("loop:interrupted", calls[2])
  Assert.equal("shutdown-2", calls[3], "shutdown should be reverse registration order")
  Assert.equal("shutdown-1", calls[4])
  Assert.equal("listener-cleanup", calls[5], "init cleanup should run after shutdown handlers")
end
Assert.endTest()

Assert.startTest("ProgramFramework captures loop and thread errors")
do
  local event = newEvent()
  local framework = ProgramFramework.new({ event = event })
  framework:registerLoop(function() error("loop failure") end)
  local ok, err = framework:start()
  Assert.isFalse(ok)
  Assert.match("loop failure", err)

  event = newEvent()
  framework = ProgramFramework.new({ event = event })
  framework:registerThread(function() error("thread failure") end)
  framework:registerLoop(function() return false end)
  ok, err = framework:start()
  Assert.isFalse(ok)
  Assert.match("thread failure", err)
end
Assert.endTest()

Assert.startTest("ProgramFramework resumes tracked coroutine threads")
do
  local event = newEvent()
  local framework = ProgramFramework.new({ event = event })
  local steps = 0
  framework:registerThread(function()
    steps = steps + 1
    coroutine.yield()
    steps = steps + 1
  end)
  framework:registerLoop(function()
    if steps == 2 then return false end
    return true
  end)
  Assert.isTrue(framework:start())
  Assert.equal(2, steps)
end
Assert.endTest()
