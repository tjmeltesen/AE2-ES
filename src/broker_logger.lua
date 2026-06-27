--[[
broker_logger.lua — Function-wrapping error logger for Exec Broker modules

Lightweight diagnostic shim that wraps critical functions with pcall
and logs errors via LogEntry + LogRingBuffer. Non-invasive — if the
logger modules aren't available, all calls degrade to no-ops.

Usage:
  local Logger = require("src.broker_logger")
  local log = Logger.new("EB-LCR-01")  -- broker ID

  -- Wrap a function to catch errors
  local result = log:wrap("phaseBUFFERING", function()
    return self:_phaseBUFFERING()
  end)

  -- Direct logging
  log:info("Buffer stabilized with %d items", count)
  log:warn("Idle timeout reached; clearing input bus")
  log:error("HAL transferItem failed", jobId)
  log:critical("Machine fault detected!", jobId)
--]]

local BrokerLogger = {}
BrokerLogger.__index = BrokerLogger

-- Lazy-load logger modules (nil if unavailable)
local LogEntry, LogRingBuffer
local function _ensureModules()
  if not LogEntry then
    local ok, mod = pcall(require, "src.log_entry")
    if ok then LogEntry = mod end
  end
  if not LogRingBuffer then
    local ok, mod = pcall(require, "src.log_ring_buffer")
    if ok then LogRingBuffer = mod end
  end
end

--- Create a new logger for a broker or component.
-- @param originId  string  "EB-LCR-01", "config_ui", etc.
-- @param bufferSize number  max ring buffer entries (default 200)
-- @return BrokerLogger
function BrokerLogger.new(originId, bufferSize)
  _ensureModules()
  local self = setmetatable({
    _originId   = originId or "unknown",
    _buffer     = LogRingBuffer and LogRingBuffer.new(bufferSize or 200) or nil,
    _wrapCount  = 0,
    _errorCount = 0,
    _warnCount  = 0,
    _lastError  = nil,
  }, BrokerLogger)
  return self
end

--- Log a message at a given severity.
-- @param severity  string  DEBUG/INFO/WARN/ERROR/CRITICAL
-- @param message   string
-- @param jobId     string|nil
function BrokerLogger:_log(severity, message, jobId)
  _ensureModules()
  local entry
  if LogEntry then
    local ok, result = pcall(LogEntry.new, LogEntry, self._originId, severity, message, jobId)
    if ok then entry = result end
  end
  if self._buffer and entry then
    pcall(self._buffer.append, self._buffer, entry)
  end
  -- Always print to terminal for immediate feedback
  local prefix = os.date and os.date("%H:%M:%S") or ""
  print(string.format("[%s] [%s] [%s] %s", prefix, severity, self._originId, message))
end

function BrokerLogger:debug(msg, jobId) self:_log("DEBUG", msg, jobId) end
function BrokerLogger:info(msg, jobId)  self:_log("INFO", msg, jobId) end
function BrokerLogger:warn(msg, jobId)  self:_log("WARN", msg, jobId); self._warnCount = (self._warnCount or 0) + 1 end
function BrokerLogger:error(msg, jobId) self:_log("ERROR", msg, jobId); self._errorCount = (self._errorCount or 0) + 1; self._lastError = msg end
function BrokerLogger:critical(msg, jobId) self:_log("CRITICAL", msg, jobId); self._errorCount = (self._errorCount or 0) + 1; self._lastError = msg end

--- Wrap a function call with error catching and logging.
-- @param funcName  string  name of the function being wrapped
-- @param fn        function  the function to call
-- @param ...       arguments to pass to fn
-- @return any  fn's return values, or nil on error
function BrokerLogger:wrap(funcName, fn, ...)
  self._wrapCount = (self._wrapCount or 0) + 1
  local ok, result = pcall(fn, ...)
  if not ok then
    self:_log("ERROR", funcName .. " failed: " .. tostring(result))
    return nil, result
  end
  return result
end

--- Get recent log entries for UI display.
-- @param count  number  default 20
-- @return table
function BrokerLogger:getRecent(count)
  if not self._buffer then return {} end
  return self._buffer:getLatest(count or 20)
end

--- Get error statistics.
-- @return table  { wrapCount, errorCount, warnCount, lastError }
function BrokerLogger:getStats()
  return {
    wrapCount  = self._wrapCount or 0,
    errorCount = self._errorCount or 0,
    warnCount  = self._warnCount or 0,
    lastError  = self._lastError,
  }
end

return BrokerLogger
