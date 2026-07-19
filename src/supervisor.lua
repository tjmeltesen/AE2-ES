-- supervisor.lua
-- AE2-ES Supervisor: Central coordinator for Exec Broker telemetry
-- Requires: modem, gpu (optional), screen (optional)
--
-- Architecture:
--   Modem subscriber loop (event.pull) → Deserialization → FIFO queue
--   → Consumers poll for processed TelemetryPayloads
--
-- Protocol:
--   Exec Brokers broadcast serialized TelemetryPayload on port SUPERVISOR_PORT
--   Supervisor never acknowledges (fire-and-forget per architectural constraint)

local TelemetryPayload = require("src.telemetrypayload")
local BoundedList = require("lib.bounded_list")

local function safeRequire(name)
  local ok, module = pcall(require, name)
  if ok then return module end
  return nil
end

local function uptime()
  local computer = safeRequire("computer")
  if computer and type(computer.uptime) == "function" then
    return computer.uptime()
  end
  return os.clock()
end

--- ============================================================
--- Configuration
--- ============================================================

local CONFIG = {
  -- Modem listening port (must match exec_broker broadcast port)
  supervisorPort = 123,
  -- Authenticated, opt-in commands only; telemetry is never sent here.
  controlPort = 124,
  enableRemoteControl = false,
  enableRemoteThrottle = false,
  enableRemoteRestart = false,
  controlAuthSecret = "",
  -- Maximum events to retain in FIFO queue per consumer poll cycle
  maxQueueSize = 1000,
  -- Queue trim threshold (how many to keep when exceeded)
  queueTrimTarget = 500,
  -- Log buffer size (in-memory circular log)
  maxLogEntries = 200,
  -- Health check interval in seconds
  healthCheckInterval = 5.0,
  -- Broker health thresholds, measured from last valid payload received
  staleThreshold = 30,
  offlineThreshold = 120,
}

--- ============================================================
--- FIFO Event Queue (TelemetryQueue)
--- ============================================================
--- Thread/FIFO-safe queue for telemetry payloads.
--- Consumers (B2 GlobalMachineMatrix, B5 Dashboard) call drain()
--- or pop() to retrieve processed payloads.

local TelemetryQueue = {}
TelemetryQueue.__index = TelemetryQueue

--- Create a new FIFO telemetry queue.
--- @param maxSize number Maximum entries before trimming
--- @param trimTarget number Entries to keep after trim
--- @return TelemetryQueue
function TelemetryQueue.new(maxSize, trimTarget)
  return setmetatable({
    _queue = BoundedList.new(
      maxSize or CONFIG.maxQueueSize,
      trimTarget or CONFIG.queueTrimTarget
    ),
    _maxSize = maxSize or CONFIG.maxQueueSize,
    _trimTarget = trimTarget or CONFIG.queueTrimTarget,
    _pushCount = 0,
    _popCount = 0,
    _droppedCount = 0,
  }, TelemetryQueue)
end

--- Push a validated telemetry payload onto the queue.
--- Trims oldest entries when maxSize exceeded to prevent memory leaks.
--- @param payload TelemetryPayload
function TelemetryQueue:push(payload)
  local beforeSize = self._queue:size()
  self._queue:push(payload)
  self._pushCount = self._pushCount + 1

  local expectedSize = beforeSize + 1
  self._droppedCount = self._droppedCount + expectedSize - self._queue:size()
end

--- Pop the oldest telemetry payload from the queue.
--- @return TelemetryPayload|nil
function TelemetryQueue:pop()
  local payload = table.remove(self._queue:toTable(), 1)
  if payload then
    self._popCount = self._popCount + 1
  end
  return payload
end

--- Peek at the oldest entry without removing it.
--- @return TelemetryPayload|nil
function TelemetryQueue:peek()
  return self._queue:toTable()[1]
end

--- Get current queue depth.
--- @return number
function TelemetryQueue:count()
  return self._queue:size()
end

--- Clear all entries. Returns the number of entries cleared.
--- @return number cleared
function TelemetryQueue:clear()
  return self._queue:clear()
end

--- Drain all entries into a new table (for batch consumer processing).
--- Efficient for consumers that process all pending messages at once.
--- @return TelemetryPayload[] entries
function TelemetryQueue:drain()
  local entries = self._queue:toTable()
  self._queue:clear()
  self._popCount = self._popCount + #entries
  return entries
end

--- Queue statistics for dashboard display.
--- @return table { count, pushed, popped, dropped }
function TelemetryQueue:stats()
  return {
    count = self._queue:size(),
    pushed = self._pushCount,
    popped = self._popCount,
    dropped = self._droppedCount,
  }
end

--- ============================================================
--- Supervisor Core
--- ============================================================

local Supervisor = {}
Supervisor.__index = Supervisor

--- Create a new Supervisor instance.
--- @param config table|nil Override default CONFIG values
--- @return Supervisor
function Supervisor.new(config)
  local cfg = {}
  for k, v in pairs(CONFIG) do
    cfg[k] = v
  end
  if config then
    for k, v in pairs(config) do
      cfg[k] = v
    end
  end

  return setmetatable({
    _config = cfg,
    _modem = nil,
    _queue = TelemetryQueue.new(cfg.maxQueueSize, cfg.queueTrimTarget),
    _activeBrokers = {},
    _running = false,
    _stopped = false,
    _consumers = {},
    _stats = {
      startTime = 0,
      messagesReceived = 0,
      messagesValid = 0,
      messagesInvalid = 0,
      lastMessageTime = 0,
      lastBrokerId = nil,
    },
    _log = BoundedList.new(cfg.maxLogEntries),
    _logIndex = 0,
    _controlHandler = nil,
  }, Supervisor)
end

--- Attach the opt-in authenticated control handler before initialize().
function Supervisor:setControlHandler(handler)
  self._controlHandler = handler
end

--- Send an authenticated, unicast control message to a configured broker.
function Supervisor:sendControl(address, brokerId, command, fields)
  if not self._controlHandler then return false, "remote control disabled" end
  return self._controlHandler:send(address, brokerId, command, fields)
end

--- Initialize the subscriber without taking ownership of event.pull().
--- Used by lib.program_framework; legacy start() retains the blocking loop.
function Supervisor:initialize()
  if self._running then return false, "supervisor already running" end
  local ok, err = self:_initModem()
  if not ok then return false, err end

  self._running = true
  self._stopped = false
  self._stats.startTime = uptime()
  self:_logMessage("INFO", "Supervisor event loop started")
  return true, nil
end

--- Process one event supplied by an external event-loop owner.
---@param signal table Event arguments as returned by event.pull()
---@return boolean Whether the supervisor should continue running
function Supervisor:handleEvent(signal)
  local signalName = signal[1]
  if signalName == "modem_message" then
    local _, _, fromAddr, port, _, payload = table.unpack(signal)
    if port == self._config.supervisorPort then
      self:_processMessage(fromAddr, port, payload)
    elseif self._controlHandler and port == self._config.controlPort then
      self._controlHandler:handle(fromAddr, port, payload)
    end
  elseif signalName == "interrupted" then
    self:_logMessage("INFO", "Interrupt signal received, shutting down")
    self._running = false
  elseif signalName == "key_down" then
    local char = signal[3]
    if char == 113 then
      self:_logMessage("INFO", "User requested shutdown (q key)")
      self._running = false
    elseif char == 115 then
      self:printStatus()
    elseif char == 99 then
      local cleared = self._queue:clear()
      self:_logMessage("INFO", string.format("Queue cleared (%d entries)", cleared))
    end
  end
  return self._running
end

--- Release modem resources once after either legacy or framework execution.
function Supervisor:shutdown()
  if self._stopped then return end
  self._stopped = true
  self._running = false
  self:_closeModem()
  self:_logMessage("INFO", "Supervisor stopped")
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Logging (Circular Buffer)
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

--- Append to circular log buffer.
--- @param level string Log level (INFO, WARN, ERROR, DEBUG)
--- @param message string Log message
function Supervisor:_logMessage(level, message)
  self._logIndex = self._logIndex + 1
  local entry = {
    id = self._logIndex,
    timestamp = uptime(),
    level = level,
    message = message,
  }
  self._log:push(entry)
end

-- Public log entry method (called by GlobalLogger, dashboard, etc.)
-- @param level string Log level (DEBUG, INFO, WARN, ERROR, CRITICAL)
-- @param message string Log message
function Supervisor:logMessage(level, message)
  self:_logMessage(level, message)
end

-- Get recent log entries.
-- @param count number|nil Number of entries to return (default: all)
-- @return table[]
function Supervisor:getLog(count)
  local log = self._log:toTable()
  if count and count < self._log:size() then
    local start = self._log:size() - count + 1
    local result = {}
    for i = start, self._log:size() do
      table.insert(result, log[i])
    end
    return result
  end
  return log
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Modem / Network Initialization
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

--- Initialize modem component and open listening port.
--- @return boolean success, string|nil error
function Supervisor:_initModem()
  local component = safeRequire("component")
  if not component or type(component.isAvailable) ~= "function" then
    return false, "component API unavailable"
  end
  if not component.isAvailable("modem") then
    return false, "no modem component available"
  end

  self._modem = component.modem

  -- Open listening port
  local ok, err = pcall(self._modem.open, self._config.supervisorPort)
  if not ok then
    return false, "failed to open port " .. self._config.supervisorPort .. ": " .. tostring(err)
  end
  if self._controlHandler and self._controlHandler:isEnabled() then
    local controlOk, controlErr = pcall(self._modem.open, self._config.controlPort)
    if not controlOk then
      pcall(self._modem.close, self._config.supervisorPort)
      return false, "failed to open control port " .. self._config.controlPort .. ": " .. tostring(controlErr)
    end
    self._controlHandler:setModem(self._modem)
  end

  self:_logMessage("INFO", string.format(
    "Modem initialized on port %d", self._config.supervisorPort
  ))
  return true, nil
end

--- Close modem port gracefully.
function Supervisor:_closeModem()
  if self._modem then
    pcall(self._modem.close, self._config.supervisorPort)
    if self._controlHandler and self._controlHandler:isEnabled() then
      pcall(self._modem.close, self._config.controlPort)
    end
    self:_logMessage("INFO", "Modem port closed")
  end
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Consumer Registration (Pub/Sub for B2, B5, etc.)
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

--- Register a consumer callback that receives new telemetry payloads.
--- Consumer receives (telemetryPayload, supervisor) on each valid message.
--- This is the pub/sub bridge for B2 GlobalMachineMatrix and B5 Dashboard.
---
--- @param name string Consumer identifier
--- @param callback function(TelemetryPayload, Supervisor)
function Supervisor:registerConsumer(name, callback)
  if type(name) ~= "string" or type(callback) ~= "function" then
    error("registerConsumer: name (string) and callback (function) required")
  end
  self._consumers[name] = callback
  self:_logMessage("INFO", string.format("Consumer registered: %s", name))
end

--- Unregister a consumer by name.
--- @param name string Consumer identifier
function Supervisor:unregisterConsumer(name)
  self._consumers[name] = nil
  self:_logMessage("INFO", string.format("Consumer unregistered: %s", name))
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Telemetry Processing Pipeline
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Pipeline: deserialize → validate → enqueue → fan-out to consumers
--- All errors are caught via pcall; a single malformed message never
--- crashes the event loop.

--- Process a single incoming modem message through the pipeline.
--- @param from string Sender component address
--- @param port number Source port
--- @param payload string Raw serialized data
function Supervisor:_processMessage(from, port, payload)
  self._stats.messagesReceived = self._stats.messagesReceived + 1
  self._stats.lastMessageTime = uptime()

  -- Step 1: Deserialize
  local telemetry, err = TelemetryPayload.deserialize(payload)
  if not telemetry then
    self._stats.messagesInvalid = self._stats.messagesInvalid + 1
    self:_logMessage("WARN", string.format(
      "Deserialization failed from %s: %s", from, err
    ))
    return
  end

  -- Step 2: Structural validation
  local valid, valErr = telemetry:validate()
  if not valid then
    self._stats.messagesInvalid = self._stats.messagesInvalid + 1
    self:_logMessage("WARN", string.format(
      "Validation failed for %s: %s", telemetry.brokerId, valErr
    ))
    return
  end

  self._stats.messagesValid = self._stats.messagesValid + 1
  self._stats.lastBrokerId = telemetry.brokerId
  self._activeBrokers[telemetry.brokerId] = uptime()

  -- Step 3: Enqueue into FIFO (for polling consumers like B5 Dashboard)
  self._queue:push(telemetry)

  -- Step 4: Fan-out to all registered consumers (for event-driven consumers like B2)
  for name, callback in pairs(self._consumers) do
    local ok, consumerErr = pcall(callback, telemetry, self)
    if not ok then
      self:_logMessage("ERROR", string.format(
        "Consumer '%s' error: %s", name, tostring(consumerErr)
      ))
    end
  end
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Main Event Loop
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Non-blocking event-driven loop. Uses event.pull() which
--- automatically yields the coroutine — no busy-waiting.
--- Signals handled:
---   modem_message  → TelemetryPayload processing pipeline
---   interrupted   → Graceful shutdown (Ctrl+C)
---   key_down      → Keyboard shortcuts (q=quit, s=status)

--- Start the main event loop. Blocks until interrupted or stop() is called.
--- @return boolean success, string|nil error
function Supervisor:start()
  local ok, err = self:initialize()
  if not ok then return false, err end

  local event = safeRequire("event")
  if not event then
    self:shutdown()
    return false, "event API unavailable"
  end
  -- Periodic health check timer (fires every healthCheckInterval seconds)
  local healthTimer = event.timer(self._config.healthCheckInterval, function()
    self:_healthCheck()
  end, math.huge)

  -- Main event loop
  -- event.pull() blocks until a signal arrives, then yields automatically
  -- This is the non-blocking architecture: no polling, no busy-waiting
  while self._running do
    local signal = {event.pull()}
    self:handleEvent(signal)
  end

  -- Cleanup
  event.cancel(healthTimer)
  self:shutdown()
  return true, nil
end

--- Signal the event loop to stop gracefully.
function Supervisor:stop()
  self._running = false
  local computer = safeRequire("computer")
  if computer and type(computer.pushSignal) == "function" then
    pcall(computer.pushSignal, "ae2es_supervisor_stop")
  end
end

--- Check if the supervisor is currently running.
--- @return boolean
function Supervisor:isRunning()
  return self._running
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Health & Status
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

--- Periodic health check (called by timer).
--- Logs warnings for queue capacity, broker silence, etc.
function Supervisor:_healthCheck()
  local queueStats = self._queue:stats()

  -- Warn if queue nearing capacity
  if queueStats.count > self._config.maxQueueSize * 0.8 then
    self:_logMessage("WARN", string.format(
      "Queue nearing capacity: %d / %d entries",
      queueStats.count, self._config.maxQueueSize
    ))
  end

  -- Log if no messages received recently
  local currentTime = uptime()
  local idleTime = currentTime - self._stats.lastMessageTime
  if self._stats.lastMessageTime > 0 and idleTime > 60 then
    self:_logMessage("INFO", string.format(
      "No messages received for %.0f seconds", idleTime
    ))
  end
end

--- Print current status summary to stdout (for interactive terminals).
function Supervisor:printStatus()
  local elapsed = uptime() - self._stats.startTime
  local queueStats = self._queue:stats()
  local sinceLastMsg = 0
  if self._stats.lastMessageTime > 0 then
    sinceLastMsg = computer.uptime() - self._stats.lastMessageTime
  end

  io.write(string.format([[
═══ AE2-ES Supervisor Status ═══
  Uptime:          %.0f seconds
  Messages:        %d received, %d valid, %d invalid
  Queue:           %d pending (%d total pushed, %d dropped)
  Last broker:     %s
  Last message:    %.0f seconds ago
  Consumers:       %d registered
════════════════════════════════
]],
    elapsed,
    self._stats.messagesReceived,
    self._stats.messagesValid,
    self._stats.messagesInvalid,
    queueStats.count,
    queueStats.pushed,
    queueStats.dropped,
    self._stats.lastBrokerId or "N/A",
    sinceLastMsg,
    self:consumerCount()
  ))

  -- Recent log entries
  io.write("── Recent Log ──\n")
  for _, entry in ipairs(self:getLog(5)) do
    io.write(string.format("  [%s] %s\n", entry.level, entry.message))
  end
  io.write(string.rep("═", 32) .. "\n")
end

--- Get number of registered consumers.
--- @return number
function Supervisor:consumerCount()
  local count = 0
  for _ in pairs(self._consumers) do
    count = count + 1
  end
  return count
end

--- Get supervisor runtime statistics as a table.
--- @return table
function Supervisor:getStats()
  local sinceLastMsg = nil
  if self._stats.lastMessageTime > 0 then
    sinceLastMsg = uptime() - self._stats.lastMessageTime
  end
  return {
    uptime = uptime() - self._stats.startTime,
    messages = {
      received = self._stats.messagesReceived,
      valid = self._stats.messagesValid,
      invalid = self._stats.messagesInvalid,
    },
    queue = self._queue:stats(),
    lastBrokerId = self._stats.lastBrokerId,
    secondsSinceLastMessage = sinceLastMsg,
    consumerCount = self:consumerCount(),
  }
end

--- Get the telemetry queue for consumers to read/drain.
--- @return TelemetryQueue
function Supervisor:getQueue()
  return self._queue
end

--- Dequeue the oldest telemetry payload.
--- @return TelemetryPayload|nil
function Supervisor:getNextPayload()
  return self._queue:pop()
end

--- Return the number of telemetry payloads waiting in the queue.
--- @return number
function Supervisor:getQueueSize()
  return self._queue:count()
end

--- Return the current health status for a broker.
--- @param brokerId string
--- @return "ACTIVE"|"STALE"|"OFFLINE"|nil
function Supervisor:getBrokerStatus(brokerId)
  local lastHeard = self._activeBrokers[brokerId]
  if lastHeard == nil then
    return nil
  end

  local elapsed = uptime() - lastHeard
  if elapsed > self._config.offlineThreshold then
    return "OFFLINE"
  elseif elapsed > self._config.staleThreshold then
    return "STALE"
  end
  return "ACTIVE"
end

--- Return a snapshot of all known brokers and their current health.
--- @return table<string, {last_heard:number, status:string}>
function Supervisor:getActiveBrokers()
  local brokers = {}
  for brokerId, lastHeard in pairs(self._activeBrokers) do
    brokers[brokerId] = {
      last_heard = lastHeard,
      status = self:getBrokerStatus(brokerId),
    }
  end
  return brokers
end

--- Get supervisor configuration (copied to prevent mutation).
--- @return table
function Supervisor:getConfig()
  local cfg = {}
  for k, v in pairs(self._config) do
    cfg[k] = v
  end
  return cfg
end

return {
  Supervisor = Supervisor,
  TelemetryPayload = TelemetryPayload,
  TelemetryQueue = TelemetryQueue,
  CONFIG = CONFIG,
}
