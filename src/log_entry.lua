-- LogEntry module
-- Immutable atomic unit for the Global Logger system.
-- Each entry carries timestamp, originId, jobId (nilable),
-- severity (DEBUG/INFO/WARN/ERROR/CRITICAL), and message.
-- Provides serialization for modem broadcast.

local LogEntry = {}
LogEntry.__index = LogEntry

-- Severity levels in ascending priority order
local SEVERITY = {
  DEBUG    = "DEBUG",
  INFO     = "INFO",
  WARN     = "WARN",
  ERROR    = "ERROR",
  CRITICAL = "CRITICAL",
}

-- Fast lookup table for validation
local VALID_SEVERITIES = {}
for k, _ in pairs(SEVERITY) do
  VALID_SEVERITIES[k] = true
end

LogEntry.SEVERITY = SEVERITY

-- Numeric severity ordering (higher = more severe)
local SEVERITY_ORDER = {
  DEBUG    = 0,
  INFO     = 1,
  WARN     = 2,
  ERROR    = 3,
  CRITICAL = 4,
}

LogEntry.SEVERITY_ORDER = SEVERITY_ORDER

-- Create a new LogEntry
-- @param originId string  identifier of the source component
-- @param severity  string  one of DEBUG/INFO/WARN/ERROR/CRITICAL
-- @param message   string  the log message
-- @param jobId     string|nil  optional job identifier
-- @return LogEntry
-- @error "invalid severity: <value>" if severity is not recognised
function LogEntry.new(originId, severity, message, jobId)
  if not VALID_SEVERITIES[severity] then
    error("invalid severity: " .. tostring(severity), 2)
  end

  local self = setmetatable({}, LogEntry)
  self.timestamp = os.epoch and os.epoch() or os.time() * 1000
  self.originId = originId
  self.severity = severity
  self.severityOrder = SEVERITY_ORDER[severity]
  self.message = message
  self.jobId = jobId or nil
  return self
end

-- Serialize to a flat telemetry payload for modem broadcast.
-- @return table  flat key-value table
function LogEntry:toTelemetryPayload()
  return {
    type = "log_entry",
    timestamp = self.timestamp,
    originId = self.originId,
    severity = self.severity,
    message = self.message,
    jobId = self.jobId,
  }
end

return LogEntry
