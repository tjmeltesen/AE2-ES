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

local component = require("component")
local event = require("event")
local serialization = require("serialization")
local computer = require("computer")

--- ============================================================
--- Configuration
--- ============================================================

local CONFIG = {
  -- Modem listening port (must match exec_broker broadcast port)
  supervisorPort = 100,
  -- Maximum events to retain in FIFO queue per consumer poll cycle
  maxQueueSize = 1000,
  -- Queue trim threshold (how many to keep when exceeded)
  queueTrimTarget = 500,
  -- Log buffer size (in-memory circular log)
  maxLogEntries = 200,
  -- Health check interval in seconds
  healthCheckInterval = 5.0,
}

--- ============================================================
--- TelemetryPayload
--- ============================================================
-- Expected structure from Exec Broker (A7 TelemetryPayload):
-- {
--   brokerId = string,              -- Unique broker identifier
--   timestamp = number,             -- os.clock() value at send time
--   queueLength = number,           -- Number of jobs in broker queue
--   hardwareMatrix = {              -- Array of machine statuses
--     { address = string,
--       status = "AVAILABLE"|"LOCKED"|"PROCESSING"|"FAULTED",
--       activeJobId = string|nil,
--       progress = number|nil },
--     ...
--   },
--   alerts = {                      -- Array of active alerts
--     { type = string,
--       severity = "INFO"|"WARNING"|"CRITICAL",
--       message = string,
--       machineAddress = string|nil },
--     ...
--   },
--   powerStored = number|nil,       -- AE2 power in subnet
--   powerMax = number|nil,          -- AE2 max power in subnet
--   cpuCount = number|nil,          -- Number of AE2 crafting CPUs
-- }

local TelemetryPayload = {}
TelemetryPayload.__index = TelemetryPayload

--- Deserialize a raw modem string into a TelemetryPayload table.
--- @param raw string Serialized Lua table from modem
--- @return TelemetryPayload|nil payload, string|nil error
function TelemetryPayload.deserialize(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, "empty or non-string payload"
  end

  local ok, data = pcall(serialization.unserialize, raw)
  if not ok or type(data) ~= "table" then
    return nil, "deserialization failed: " .. tostring(data)
  end

  -- Validate required fields
  if type(data.brokerId) ~= "string" or data.brokerId == "" then
    return nil, "missing or invalid brokerId"
  end

  return setmetatable(data, TelemetryPayload), nil
end

--- Validate the payload structure for required fields.
--- @return boolean valid, string|nil error
function TelemetryPayload:validate()
  if type(self.timestamp) ~= "number" then
    return false, "missing timestamp"
  end
  if type(self.hardwareMatrix) ~= "table" then
    return false, "missing hardwareMatrix"
  end
  if type(self.alerts) ~= "table" then
    self.alerts = {} -- default to empty
  end
  return true, nil
end

--- Human-readable summary for logging and dashboard.
--- @return string
function TelemetryPayload:summary()
  local machineCount = #(self.hardwareMatrix or {})
  local alertCount = #(self.alerts or {})
  local faultedCount = 0
  for _, m in ipairs(self.hardwareMatrix or {}) do
    if m.status == "FAULTED" then
      faultedCount = faultedCount + 1
    end
  end
  return string.format(
    "[%s] %d machines (%d faulted), %d alerts, queue=%d",
    self.brokerId, machineCount, faultedCount, alertCount,
    self.queueLength or 0
  )
end

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
    _queue = {},
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
  table.insert(self._queue, payload)
  self._pushCount = self._pushCount + 1

  -- Trim if over capacity
  if #self._queue > self._maxSize then
    local toRemove = #self._queue - self._trimTarget
    for _ = 1, toRemove do
      table.remove(self._queue, 1)
    end
    self._droppedCount = self._droppedCount + toRemove
  end
end

--- Pop the oldest telemetry payload from the queue.
--- @return TelemetryPayload|nil
function TelemetryQueue:pop()
  local payload = table.remove(self._queue, 1)
  if payload then
    self._popCount = self._popCount + 1
  end
  return payload
end

--- Peek at the oldest entry without removing it.
--- @return TelemetryPayload|nil
function TelemetryQueue:peek()
  return self._queue[1]
end

--- Get current queue depth.
--- @return number
function TelemetryQueue:count()
  return #self._queue
end

--- Clear all entries. Returns the number of entries cleared.
--- @return number cleared
function TelemetryQueue:clear()
  local count = #self._queue
  self._queue = {}
  return count
end

--- Drain all entries into a new table (for batch consumer processing).
--- Efficient for consumers that process all pending messages at once.
--- @return TelemetryPayload[] entries
function TelemetryQueue:drain()
  local entries = self._queue
  self._queue = {}
  self._popCount = self._popCount + #entries
  return entries
end

--- Queue statistics for dashboard display.
--- @return table { count, pushed, popped, dropped }
function TelemetryQueue:stats()
  return {
    count = #self._queue,
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
    _running = false,
    _consumers = {},
    _stats = {
      startTime = 0,
      messagesReceived = 0,
      messagesValid = 0,
      messagesInvalid = 0,
      lastMessageTime = 0,
      lastBrokerId = nil,
    },
    _log = {},
    _logIndex = 0,
  }, Supervisor)
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
    timestamp = computer.uptime(),
    level = level,
    message = message,
  }
  table.insert(self._log, entry)
  if #self._log > self._config.maxLogEntries then
    table.remove(self._log, 1)
  end
end

--- Get recent log entries.
--- @param count number|nil Number of entries to return (default: all)
--- @return table[]
function Supervisor:getLog(count)
  if count and count < #self._log then
    local start = #self._log - count + 1
    local result = {}
    for i = start, #self._log do
      table.insert(result, self._log[i])
    end
    return result
  end
  return self._log
end

--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---
--- Modem / Network Initialization
--- --- --- --- --- --- --- --- --- --- --- --- --- --- --- ---

--- Initialize modem component and open listening port.
--- @return boolean success, string|nil error
function Supervisor:_initModem()
  if not component.isAvailable("modem") then
    return false, "no modem component available"
  end

  self._modem = component.modem

  -- Open listening port
  local ok, err = pcall(self._modem.open, self._modem, self._config.supervisorPort)
  if not ok then
    return false, "failed to open port " .. self._config.supervisorPort .. ": " .. tostring(err)
  end

  self:_logMessage("INFO", string.format(
    "Modem initialized on port %d", self._config.supervisorPort
  ))
  return true, nil
end

--- Close modem port gracefully.
function Supervisor:_closeModem()
  if self._modem then
    pcall(self._modem.close, self._modem, self._config.supervisorPort)
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
  self._stats.lastMessageTime = computer.uptime()

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
  if self._running then
    return false, "supervisor already running"
  end

  -- Initialize modem
  local ok, err = self:_initModem()
  if not ok then
    return false, err
  end

  self._running = true
  self._stats.startTime = computer.uptime()
  self:_logMessage("INFO", "Supervisor event loop started")

  -- Periodic health check timer (fires every healthCheckInterval seconds)
  local healthTimer = event.timer(self._config.healthCheckInterval, function()
    self:_healthCheck()
  end, math.huge)

  -- Main event loop
  -- event.pull() blocks until a signal arrives, then yields automatically
  -- This is the non-blocking architecture: no polling, no busy-waiting
  while self._running do
    local signal = {event.pull()}
    local signalName = signal[1]

    if signalName == "modem_message" then
      -- modem_message arguments:
      --   (_, _, fromAddr, port, distance, ...payload...)
      local _, _, fromAddr, port, _, payload = table.unpack(signal)

      -- Filter to our port only (modem_message arrives for all open ports)
      if port == self._config.supervisorPort then
        self:_processMessage(fromAddr, port, payload)
      end

    elseif signalName == "interrupted" then
      -- Ctrl+C or shutdown signal from the OS
      self:_logMessage("INFO", "Interrupt signal received, shutting down")
      self._running = false

    elseif signalName == "key_down" then
      -- Keyboard shortcuts for interactive control
      -- signal[3] = char code, signal[4] = key code
      local char = signal[3]
      if char == 113 then         -- 'q' key: quit
        self:_logMessage("INFO", "User requested shutdown (q key)")
        self._running = false
      elseif char == 115 then     -- 's' key: print status
        self:printStatus()
      elseif char == 99 then      -- 'c' key: clear queue
        local cleared = self._queue:clear()
        self:_logMessage("INFO", string.format(
          "Queue cleared (%d entries)", cleared
        ))
      end
    end
  end

  -- Cleanup
  event.cancel(healthTimer)
  self:_closeModem()
  self:_logMessage("INFO", "Supervisor stopped")
  return true, nil
end

--- Signal the event loop to stop gracefully.
function Supervisor:stop()
  self._running = false
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
  local uptime = computer.uptime()
  local idleTime = uptime - self._stats.lastMessageTime
  if self._stats.lastMessageTime > 0 and idleTime > 60 then
    self:_logMessage("INFO", string.format(
      "No messages received for %.0f seconds", idleTime
    ))
  end
end

--- Print current status summary to stdout (for interactive terminals).
function Supervisor:printStatus()
  local uptime = computer.uptime() - self._stats.startTime
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
    uptime,
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
    sinceLastMsg = computer.uptime() - self._stats.lastMessageTime
  end
  return {
    uptime = computer.uptime() - self._stats.startTime,
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

--- Get supervisor configuration (copied to prevent mutation).
--- @return table
function Supervisor:getConfig()
  local cfg = {}
  for k, v in pairs(self._config) do
    cfg[k] = v
  end
  return cfg
end

--- ============================================================
--- Module Exports
--- ============================================================

return {
  Supervisor = Supervisor,
  TelemetryPayload = TelemetryPayload,
  TelemetryQueue = TelemetryQueue,
  CONFIG = CONFIG,
}

-- ===========================================================================
-- Entry point — run as standalone script
-- ===========================================================================
-- When executed directly, load config (or run config UI) and start.
-- Wrapped in pcall for vanilla Lua environments.
if arg and (#arg == 0 or arg[0]:match("supervisor")) then
  local ok, err = pcall(function()
    local cfgPath = "/home/ae2es_supervisor.cfg"
    local cfgFile = io.open(cfgPath, "r")
    local config = nil

    if cfgFile then
      local raw = cfgFile:read("*a")
      cfgFile:close()
      local ok2, result = pcall(loadstring("return " .. raw))
      if ok2 and type(result) == "table" then
        config = result
        print("Loaded config from " .. cfgPath)
      end
    end

    if not config then
      print("No config found. Running config UI first...")
      local ConfigUI = require("supervisor.config_ui")
      local cfg = ConfigUI.run_or_wizard()
      if cfg then
        ConfigUI.save_config(cfg)
        config = cfg
      end
      if not config then
        error("Configuration cancelled — cannot start supervisor without config")
      end
    end

    local sv = Supervisor.new(config)
    print("Starting Supervisor on port " .. (config.supervisorPort or 100))
    sv:start()
  end)
  if not ok then
    print("Supervisor requires OpenComputers runtime")
    print("Error: " .. tostring(err))
  end
end
