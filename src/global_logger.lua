--[[
global_logger.lua — Global Logger integration for AE2-ES Supervisor (Task D3)

Registers as a consumer with the Supervisor's modem subscriber loop.
On each TelemetryPayload received:
  - Extracts alerts array from the payload
  - Creates LogEntry for each alert with originId=brokerId
  - Routes by severity:
    - DEBUG/INFO: stored locally only (LogRingBuffer)
    - WARN: stored + transmitted to Supervisor LogRingBuffer
    - ERROR/CRITICAL: stored + Supervisor log + UI alert flash
      + maintenance flag snapshot

Integration points:
  - Consumer registration via Supervisor:registerConsumer()
  - Log viewer data via Supervisor:getLog()
  - UI alert flash via Supervisor alert flash state
  - Dashboard log viewer tab (L key)
  - LogExporter flush to /home/logs/ae2-es_system.log

Dependencies:
  - LogEntry (src/log_entry.lua)
  - LogRingBuffer (src/log_ring_buffer.lua)
--]]

local LogEntry     = require("lib.log_entry")
local LogRingBuffer = require("lib.log_ring_buffer")

-- ============================================================================
-- LogFilter — Filter log entries by severity, origin, or text search
-- ============================================================================

local LogFilter = {}
LogFilter.__index = LogFilter

-- Create a new LogFilter instance.
function LogFilter.new()
  return setmetatable({}, LogFilter)
end

-- Filter entries by a set of severities.
-- @param entries  LogEntry[]  Array of LogEntry objects
-- @param severities table|nil  Set of allowed severity strings (e.g. {"ERROR", "CRITICAL"})
--        nil means no severity filtering
-- @return LogEntry[] filtered array
function LogFilter:bySeverity(entries, severities)
  if not severities or #severities == 0 then
    return entries
  end
  -- Build fast lookup
  local sevSet = {}
  for _, s in ipairs(severities) do
    sevSet[s] = true
  end
  local result = {}
  for _, entry in ipairs(entries) do
    if sevSet[entry.severity] then
      table.insert(result, entry)
    end
  end
  return result
end

-- Filter entries by origin (brokerId).
-- @param entries  LogEntry[]
-- @param origin   string|nil  originId to match; nil means no filtering
-- @return LogEntry[] filtered array
function LogFilter:byOrigin(entries, origin)
  if not origin or origin == "" then
    return entries
  end
  local result = {}
  for _, entry in ipairs(entries) do
    if entry.originId == origin then
      table.insert(result, entry)
    end
  end
  return result
end

-- Search entries by text in message field.
-- @param entries  LogEntry[]
-- @param query    string|nil  search string; nil or "" means no search
-- @return LogEntry[] filtered array
function LogFilter:byText(entries, query)
  if not query or query == "" then
    return entries
  end
  local q = query:lower()
  local result = {}
  for _, entry in ipairs(entries) do
    local msg = (entry.message or ""):lower()
    if msg:find(q, 1, true) then
      table.insert(result, entry)
    end
  end
  return result
end

-- Combined filter with all options.
-- @param entries  LogEntry[]
-- @param opts     table  { severities = {"ERROR",...}, origin = "broker1", search = "error text" }
-- @return LogEntry[]
function LogFilter:filter(entries, opts)
  opts = opts or {}
  local result = entries
  result = self:bySeverity(result, opts.severities)
  result = self:byOrigin(result, opts.origin)
  result = self:byText(result, opts.search)
  return result
end

-- ============================================================================
-- LogExporter — Write log entries to disk with rotation
-- ============================================================================

local LogExporter = {}
LogExporter.__index = LogExporter

local DEFAULT_LOG_PATH = "/home/logs/ae2-es_system.log"
local DEFAULT_MAX_FILE_SIZE = 10 * 1024 * 1024  -- 10 MB
local DEFAULT_MAX_FILES = 5

-- Create a new LogExporter instance.
-- @param config table { logPath, maxFileSize, maxFiles }
function LogExporter.new(config)
  config = config or {}
  local self = setmetatable({
    _logPath = config.logPath or DEFAULT_LOG_PATH,
    _maxFileSize = config.maxFileSize or DEFAULT_MAX_FILE_SIZE,
    _maxFiles = config.maxFiles or DEFAULT_MAX_FILES,
    _buffer = {},        -- entries queued for write
    _fileHandle = nil,   -- current open file handle (nil in standalone test)
    _bytesWritten = 0,   -- approx bytes written to current file
    _fileIndex = 0,      -- current rotation index
  }, LogExporter)
  return self
end

-- Queue a log entry for writing. Entries are flushed in batch.
-- @param entry LogEntry or table with timestamp, severity, originId, message
function LogExporter:append(entry)
  table.insert(self._buffer, entry)
end

-- Format a log entry as a log line string.
-- @param entry table
-- @return string
function LogExporter:_formatEntry(entry)
  local ts = entry.timestamp or os.time()
  local sev = entry.severity or "INFO"
  local origin = entry.originId or "system"
  local msg = entry.message or ""
  return string.format("[%d] [%s] [%s] %s\n", ts, sev, origin, msg)
end

-- Write all buffered entries to the log file.
-- Uses io.open for standalone/OC compatibility.
function LogExporter:flush()
  if #self._buffer == 0 then
    return
  end

  local content = {}
  for _, entry in ipairs(self._buffer) do
    table.insert(content, self:_formatEntry(entry))
  end
  self._buffer = {}

  -- Attempt file write (may fail in environments without filesystem)
  local ok, fh = pcall(io.open, self._logPath, "a")
  if ok and fh then
    fh:write(table.concat(content))
    self._bytesWritten = self._bytesWritten + #table.concat(content)
    pcall(fh.close, fh)
  end
end

-- Check if file rotation is needed and rotate if so.
function LogExporter:checkRotation()
  if self._bytesWritten < self._maxFileSize then
    return
  end

  -- Rotate: move current log to .1, .2, etc.
  self._fileIndex = self._fileIndex + 1

  -- Archive current file (best-effort, may fail if no filesystem)
  local archivePath = self._logPath .. "." .. self._fileIndex
  local ok, renameErr = pcall(os.rename, self._logPath, archivePath)
  if not ok then
    -- Filesystem not available (standalone test); just reset counter
    self._bytesWritten = 0
    return
  end

  -- Clean up old rotated files beyond maxFiles
  if self._fileIndex > self._maxFiles then
    local oldestPath = self._logPath .. "." .. (self._fileIndex - self._maxFiles)
    pcall(os.remove, oldestPath)
  end

  self._bytesWritten = 0
end

-- Get the current log file path.
-- @return string
function LogExporter:getLogPath()
  return self._logPath
end

-- Get the number of buffered (unflushed) entries.
-- @return number
function LogExporter:getBufferSize()
  return #self._buffer
end

-- ============================================================================
-- GlobalLogger — Supervisor integration module
-- ============================================================================

local GlobalLogger = {}
GlobalLogger.__index = GlobalLogger

-- Map TelemetryPayload alert severity to LogEntry severity.
-- Telemetry alerts use "WARNING" while LogEntry uses "WARN".
local function mapAlertSeverity(alertSev)
  if alertSev == "WARNING" then
    return "WARN"
  end
  if alertSev == "CRITICAL" then
    return "CRITICAL"
  end
  if alertSev == "ERROR" then
    return "ERROR"
  end
  if alertSev == "INFO" then
    return "INFO"
  end
  if alertSev == "DEBUG" then
    return "DEBUG"
  end
  -- Default to INFO for unknown severities
  return "INFO"
end

-- Severity levels that trigger full propagation (WARN and above)
local SEVERITY_WARN_ORDER = LogEntry.SEVERITY_ORDER.WARN  -- 2

-- Create a new GlobalLogger instance.
-- @param config table|nil  Override defaults
--   { localBufferSize = 500, logPath = "/home/logs/ae2-es_system.log" }
-- @return GlobalLogger
function GlobalLogger.new(config)
  config = config or {}
  local self = setmetatable({
    _localBuffer = LogRingBuffer.new(config.localBufferSize or 500),
    _filter = LogFilter.new(),
    _exporter = LogExporter.new({ logPath = config.logPath }),
    _config = config,
    _alertFlash = false,          -- set on ERROR/CRITICAL, cleared by dashboard
    _maintenanceSnapshots = {},   -- table of { brokerId, timestamp, machines }
    _totalProcessed = 0,          -- counter for processed payloads
    _totalEntries = 0,            -- counter for created log entries
    _totalAlertsBySeverity = {    -- severity breakdown
      DEBUG = 0, INFO = 0, WARN = 0, ERROR = 0, CRITICAL = 0,
    },
  }, GlobalLogger)
  return self
end

-- Register this GlobalLogger as a consumer with the Supervisor.
-- The Supervisor will invoke the callback on each valid TelemetryPayload.
-- @param supervisor  Supervisor instance
function GlobalLogger:register(supervisor)
  supervisor:registerConsumer("global_logger", function(payload, sv)
    self:_process(payload, sv)
  end)
end

-- Process a TelemetryPayload: extract alerts, create LogEntries, route by severity.
-- @param payload    TelemetryPayload
-- @param supervisor Supervisor instance
function GlobalLogger:_process(payload, supervisor)
  local brokerId = payload.brokerId or "unknown"
  local alerts = payload.alerts or {}
  local hardwareMatrix = payload.hardwareMatrix or {}
  local hasCritical = false
  local hasError = false

  for _, alert in ipairs(alerts) do
    local severity = mapAlertSeverity(alert.severity or "INFO")
    local jobId = alert.machineAddress or nil

    -- Create LogEntry for this alert
    local entry = LogEntry.new(brokerId, severity, alert.message, jobId)

    -- Update counters
    self._totalEntries = self._totalEntries + 1
    if self._totalAlertsBySeverity[severity] ~= nil then
      self._totalAlertsBySeverity[severity] = self._totalAlertsBySeverity[severity] + 1
    end

    -- === Severity Routing ===
    if severity == "DEBUG" or severity == "INFO" then
      -- DEBUG/INFO: store locally only
      self._localBuffer:append(entry)

    elseif severity == "WARN" then
      -- WARN: store locally + Supervisor log
      self._localBuffer:append(entry)
      self:_logToSupervisor(supervisor, "WARN", brokerId, alert.message)
      -- Queue for disk export
      self._exporter:append(entry)

    elseif severity == "ERROR" then
      -- ERROR: store locally + Supervisor log + UI alert flash
      self._localBuffer:append(entry)
      self:_logToSupervisor(supervisor, "ERROR", brokerId, alert.message)
      self._exporter:append(entry)
      hasError = true

    elseif severity == "CRITICAL" then
      -- CRITICAL: store locally + Supervisor log + UI alert flash
      -- + capture maintenance flag snapshot
      self._localBuffer:append(entry)
      self:_logToSupervisor(supervisor, "CRITICAL", brokerId, alert.message)
      self._exporter:append(entry)
      hasCritical = true

      -- Capture maintenance flag snapshot from hardwareMatrix
      local snapshot = self:_captureMaintenanceSnapshot(brokerId, hardwareMatrix)
      if snapshot then
        table.insert(self._maintenanceSnapshots, snapshot)
        -- Keep only last 50 snapshots
        if #self._maintenanceSnapshots > 50 then
          table.remove(self._maintenanceSnapshots, 1)
        end
      end
    end
  end

  -- Set alert flash flag for the dashboard
  if hasCritical or hasError then
    self._alertFlash = true
    -- Also set the supervisor's flash state so the dashboard can read it
    supervisor._loggerAlertFlash = true
  end

  -- LogExporter: flush after each TelemetryPayload batch
  self._exporter:flush()
  self._exporter:checkRotation()

  self._totalProcessed = self._totalProcessed + 1
end

-- Write a log message to the Supervisor's internal log buffer.
-- Uses public interface if available, falls back to _logMessage.
-- @param supervisor  Supervisor instance
-- @param level       string  severity level
-- @param brokerId    string  source broker identifier
-- @param message     string  alert message
function GlobalLogger:_logToSupervisor(supervisor, level, brokerId, message)
  local formatted = string.format("[%s] %s", brokerId, message)
  if supervisor.logMessage then
    supervisor:logMessage(level, formatted)
  elseif supervisor._logMessage then
    supervisor:_logMessage(level, formatted)
  end
end

-- Capture a maintenance flag snapshot from the hardware matrix.
-- Looks for FAULTED machines and records their status.
-- @param brokerId  string
-- @param hardwareMatrix table[]  Array of machine status objects
-- @return table|nil  { brokerId, timestamp, faultedMachines }
function GlobalLogger:_captureMaintenanceSnapshot(brokerId, hardwareMatrix)
  local faultedMachines = {}
  for _, machine in ipairs(hardwareMatrix or {}) do
    if machine.status == "FAULTED" then
      table.insert(faultedMachines, {
        address = machine.address or "unknown",
        status = machine.status,
        activeJobId = machine.activeJobId,
        progress = machine.progress,
        maintenanceFlags = machine.maintenanceFlags or {},
      })
    end
  end

  if #faultedMachines == 0 then
    -- No FAULTED machines; still capture as empty snapshot for audit
    faultedMachines = nil
  end

  return {
    brokerId = brokerId,
    timestamp = os.epoch and os.epoch() or os.time() * 1000,
    faultedCount = faultedMachines and #faultedMachines or 0,
    faultedMachines = faultedMachines,
  }
end

-- ============================================================================
-- Public query methods for UI and tests
-- ============================================================================

-- Get the local LogRingBuffer instance.
-- @return LogRingBuffer
function GlobalLogger:getLocalBuffer()
  return self._localBuffer
end

-- Get the LogFilter instance.
-- @return LogFilter
function GlobalLogger:getFilter()
  return self._filter
end

-- Get the LogExporter instance.
-- @return LogExporter
function GlobalLogger:getExporter()
  return self._exporter
end

-- Get recent local log entries, optionally filtered.
-- @param opts table|nil  Filter options: { severities, origin, search, limit }
-- @return LogEntry[]
function GlobalLogger:getEntries(opts)
  opts = opts or {}
  local entries = self._localBuffer:getAll()
  local filtered = self._filter:filter(entries, opts)
  if opts.limit and #filtered > opts.limit then
    local result = {}
    for i = #filtered - opts.limit + 1, #filtered do
      table.insert(result, filtered[i])
    end
    return result
  end
  return filtered
end

-- Get maintenance snapshots.
-- @param limit number|nil  Max snapshots to return (default: all)
-- @return table[]
function GlobalLogger:getMaintenanceSnapshots(limit)
  if not limit or limit >= #self._maintenanceSnapshots then
    return self._maintenanceSnapshots
  end
  local result = {}
  local start = #self._maintenanceSnapshots - limit + 1
  for i = start, #self._maintenanceSnapshots do
    table.insert(result, self._maintenanceSnapshots[i])
  end
  return result
end

-- Check if there's a pending alert flash (ERROR/CRITICAL).
-- The dashboard reads this to show the flash indicator.
-- @return boolean
function GlobalLogger:hasAlertFlash()
  return self._alertFlash
end

-- Clear the alert flash state after the dashboard has displayed it.
function GlobalLogger:clearAlertFlash()
  self._alertFlash = false
end

-- Get processing statistics.
-- @return table
function GlobalLogger:getStats()
  return {
    totalProcessed = self._totalProcessed,
    totalEntries = self._totalEntries,
    alertsBySeverity = self._totalAlertsBySeverity,
    localBufferCount = self._localBuffer:count(),
    maintenanceSnapshotCount = #self._maintenanceSnapshots,
    exporterBufferSize = self._exporter:getBufferSize(),
    logPath = self._exporter:getLogPath(),
  }
end

-- Get the log file path.
-- @return string
function GlobalLogger:getLogPath()
  return self._exporter:getLogPath()
end

return {
  GlobalLogger = GlobalLogger,
  LogFilter = LogFilter,
  LogExporter = LogExporter,
}
