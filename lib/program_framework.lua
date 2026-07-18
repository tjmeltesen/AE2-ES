-- Shared lifecycle owner for AE2-ES programs.
-- OC APIs are loaded only when a framework instance starts.

local ProgramFramework = {}
ProgramFramework.__index = ProgramFramework

local function protected(callback, ...)
  local args = { ... }
  return xpcall(function()
    return callback(table.unpack(args))
  end, function(err)
    return tostring(err)
  end)
end

function ProgramFramework.new(options)
  options = options or {}
  return setmetatable({
    _event = options.event,
    _pollInterval = options.pollInterval or 0.05,
    _inits = {},
    _loops = {},
    _timers = {},
    _threads = {},
    _shutdowns = {},
    _cleanups = {},
    _running = false,
    _stopped = false,
    _error = nil,
  }, ProgramFramework)
end

function ProgramFramework:registerInit(callback)
  assert(type(callback) == "function", "registerInit requires a function")
  table.insert(self._inits, callback)
  return callback
end

function ProgramFramework:registerLoop(callback)
  assert(type(callback) == "function", "registerLoop requires a function")
  table.insert(self._loops, callback)
  return callback
end

function ProgramFramework:registerTimer(interval, callback, count)
  assert(type(interval) == "number" and interval > 0, "registerTimer requires a positive interval")
  assert(type(callback) == "function", "registerTimer requires a function")
  local timer = { interval = interval, callback = callback, count = count or math.huge }
  table.insert(self._timers, timer)
  return timer
end

function ProgramFramework:registerThread(callback)
  assert(type(callback) == "function", "registerThread requires a function")
  local thread = { callback = callback }
  table.insert(self._threads, thread)
  return thread
end

function ProgramFramework:registerShutdown(callback)
  assert(type(callback) == "function", "registerShutdown requires a function")
  table.insert(self._shutdowns, callback)
  return callback
end

function ProgramFramework:_fail(err)
  self._error = tostring(err)
  self._running = false
end

function ProgramFramework:_runCleanups(event)
  if self._stopped then return end
  self._stopped = true

  for _, timer in ipairs(self._timers) do
    if timer.handle and event and type(event.cancel) == "function" then
      pcall(event.cancel, timer.handle)
    end
  end
  for index = #self._shutdowns, 1, -1 do
    pcall(self._shutdowns[index])
  end
  for index = #self._cleanups, 1, -1 do
    pcall(self._cleanups[index])
  end
end

function ProgramFramework:exit(reason)
  if reason and not self._error then
    self._error = tostring(reason)
  end
  self._running = false
  self:_runCleanups(self._event)
  return self._error == nil, self._error
end

function ProgramFramework:start()
  if self._running then return false, "program framework already running" end
  self._stopped = false
  self._error = nil

  local event = self._event
  if not event then
    local ok, loaded = pcall(require, "event")
    if not ok then return false, "event API unavailable: " .. tostring(loaded) end
    event = loaded
    self._event = event
  end
  if type(event.pull) ~= "function" then
    return false, "event.pull is required"
  end

  for _, init in ipairs(self._inits) do
    local ok, cleanup = protected(init)
    if not ok then
      self:_fail(cleanup)
      self:_runCleanups(event)
      return false, self._error
    end
    if type(cleanup) == "function" then table.insert(self._cleanups, cleanup) end
  end

  for _, timer in ipairs(self._timers) do
    if type(event.timer) == "function" then
      timer.handle = event.timer(timer.interval, function(...)
        local ok, err = protected(timer.callback, ...)
        if not ok then self:_fail(err) end
      end, timer.count)
    end
  end

  for _, thread in ipairs(self._threads) do
    thread.coroutine = coroutine.create(thread.callback)
  end

  self._running = true
  while self._running do
    for index = #self._threads, 1, -1 do
      local thread = self._threads[index]
      local ok, err = coroutine.resume(thread.coroutine)
      if not ok then
        self:_fail(err)
        break
      end
      if coroutine.status(thread.coroutine) == "dead" then
        table.remove(self._threads, index)
      end
    end
    if not self._running then break end

    local signal = { event.pull(self._pollInterval) }
    for _, loop in ipairs(self._loops) do
      local ok, keepRunning = protected(loop, signal)
      if not ok then
        self:_fail(keepRunning)
        break
      end
      if keepRunning == false then
        self._running = false
        break
      end
    end
  end

  self:_runCleanups(event)
  return self._error == nil, self._error
end

return ProgramFramework
