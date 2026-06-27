--[[
log_exporter.lua — LogExporter (D2)
AE2 Execution System (AE2-ES)

Batching disk I/O subsystem for the Global Logger.
Writes staged log entries to disk via the OC filesystem API.
Handles time-based flushing, batch-threshold flushing, and disk rotation.

Log file path: /home/logs/ae2-es_system.log
Backup file:   /home/logs/ae2-es_system.log.old

Disk rotation strategy:
  1. If current log exceeds 512 KB, rename to .old and create a fresh file.
  2. This guarantees at most ~1 MB total disk usage (current + one backup).

Cooperative yielding: os.sleep(0) is called during file writes to prevent
OC timeout errors from long-running IO operations.

Dependencies:
  - io (OC filesystem API: io.open, io.lines)
  - os (os.time, os.clock, os.sleep)
  - filesystem (OC filesystem.size for rotation checks)
]]

local LogExporter = {}
LogExporter.__index = LogExporter

-- Default configuration
local DEFAULT_BATCH_THRESHOLD  = 20
local DEFAULT_FLUSH_INTERVAL   = 60  -- seconds
local DEFAULT_LOG_DIR          = "/home/logs"
local DEFAULT_LOG_FILE         = "/home/logs/ae2-es_system.log"
local DEFAULT_LOG_FILE_OLD     = "/home/logs/ae2-es_system.log.old"
local DEFAULT_ROTATION_SIZE    = 512 * 1024  -- 512 KB in bytes

-- ===========================================================================
-- Constructor
-- ===========================================================================

--- Create a new LogExporter instance.
--
-- @param opts  table, optional keys:
--   batchThreshold  — number of entries before forced flush (default 20)
--   flushInterval   — seconds between time-based flushes (default 60)
--   logPath         — custom log file path (default /home/logs/ae2-es_system.log)
--   logPathOld      — custom .old backup path
--   rotationSize    — bytes before triggering rotation (default 512*1024)
--   filesystem      — injected filesystem mock (for testing)
--   ioProvider      — injected io mock (for testing)
-- @return LogExporter
function LogExporter.new(opts)
  opts = opts or {}

  local self = setmetatable({
    -- Configuration
    _batchThreshold = opts.batchThreshold or DEFAULT_BATCH_THRESHOLD,
    _flushInterval  = opts.flushInterval  or DEFAULT_FLUSH_INTERVAL,
    _logPath        = opts.logPath        or DEFAULT_LOG_FILE,
    _logPathOld     = opts.logPathOld     or DEFAULT_LOG_FILE_OLD,
    _rotationSize   = opts.rotationSize   or DEFAULT_ROTATION_SIZE,

    -- State
    _writeBuffer     = {},
    _bufferCount     = 0,
    _lastFlushTime   = os.clock(),
    _totalFlushed    = 0,
    _totalRotations  = 0,

    -- Injected dependencies (for testing)
    _ioProvider      = opts.ioProvider     or io,
    _filesystem      = opts.filesystem     or nil,
  }, LogExporter)

  return self
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Stage a log entry for deferred write to disk.
-- If the write buffer reaches the batch threshold, triggers an immediate flush.
--
-- @param logEntry  table — log entry with {timestamp, severity, originId, message}
-- @return boolean  true if staged successfully
function LogExporter:stage(logEntry)
  if type(logEntry) ~= "table" then
    return false
  end

  table.insert(self._writeBuffer, logEntry)
  self._bufferCount = self._bufferCount + 1

  -- Auto-flush if at or above batch threshold
  if self._bufferCount >= self._batchThreshold then
    self:flushToHDD()
  end

  return true
end

--- Force-flush the write buffer to disk regardless of batch threshold.
-- Appends all staged entries to the log file, then clears the buffer.
-- Handles rotation before write if the log file exceeds the rotation limit.
-- Calls os.sleep(0) for cooperative multitasking during writes.
--
-- @return boolean  true if flush was performed (may still be partial on IO error)
--                  false if buffer was empty (no-op)
function LogExporter:flushToHDD()
  if self._bufferCount == 0 then
    return false
  end

  -- Ensure log directory exists
  self:_ensureLogDir()

  -- Check and perform disk rotation if needed
  self:_checkRotation()

  -- Build the text block to append
  local lines = {}
  for i = 1, self._bufferCount do
    local entry = self._writeBuffer[i]
    if entry then
      table.insert(lines, self:_formatEntry(entry))
    end
  end
  local text = table.concat(lines, "\n") .. "\n"

  -- Open in append mode and write
  local ok, err = self:_appendToFile(self._logPath, text)
  if not ok then
    -- Write failed — keep buffer for retry
    return false
  end

  -- Clear the write buffer
  self._writeBuffer = {}
  self._bufferCount = 0
  self._lastFlushTime = os.clock()
  self._totalFlushed = self._totalFlushed + 1

  return true
end

--- Perform a time-based flush if enough time has elapsed since the last flush.
-- Designed to be called from the main loop each cycle.
--
-- @return boolean  true if flush was performed, false otherwise
function LogExporter:tick()
  local now = os.clock()
  if self._bufferCount > 0 and (now - self._lastFlushTime) >= self._flushInterval then
    return self:flushToHDD()
  end
  return false
end

--- Get diagnostic stats about the exporter.
-- @return table  { bufferCount, batchThreshold, totalFlushed, totalRotations,
--                  lastFlushTime, logPath, logPathOld }
function LogExporter:getStats()
  return {
    bufferCount    = self._bufferCount,
    batchThreshold = self._batchThreshold,
    totalFlushed   = self._totalFlushed,
    totalRotations = self._totalRotations,
    lastFlushTime  = self._lastFlushTime,
    logPath        = self._logPath,
    logPathOld     = self._logPathOld,
  }
end

-- ===========================================================================
-- Internal helpers
-- ===========================================================================

--- Ensure the log directory exists, creating it if necessary.
-- On OC, uses filesystem.makeDirectory; on vanilla Lua, io.open creates files only.
function LogExporter:_ensureLogDir()
  local dir = DEFAULT_LOG_DIR
  -- Try OC filesystem API first
  local fs = self._filesystem or (pcall(require, "filesystem") and require("filesystem"))
  if fs and fs.exists then
    local exists = fs.exists(dir)
    if not exists then
      local ok, err = pcall(fs.makeDirectory, dir)
      if not ok then
        -- Silently fail — log file write will report the error
      end
    end
  end
end

--- Format a log entry as a single text line for disk writing.
-- Format:  [timestamp] SEVERITY  originId  message
-- @param entry  table — log entry
-- @return string
function LogExporter:_formatEntry(entry)
  local ts = tostring(entry.timestamp or os.time())
  local sev = tostring(entry.severity or "INFO")
  local oid = tostring(entry.originId or "?")
  local msg = tostring(entry.message or "")
  return string.format("[%s] %s  %s  %s", ts, sev, oid, msg)
end

--- Append text to a file in append mode.
-- Uses the injected io provider (OC io.open with append mode).
-- Calls os.sleep(0) before open to allow cooperative yielding.
-- @param path  string — file path
-- @param text  string — content to append
-- @return boolean ok, string|nil error
function LogExporter:_appendToFile(path, text)
  -- Cooperative yield before IO
  if os.sleep then
    os.sleep(0)
  end

  local io = self._ioProvider
  local ok, fh = pcall(io.open, path, "a")
  if not ok or not fh then
    return false, "failed to open " .. tostring(path) .. " for append"
  end

  local writeOk, writeErr = pcall(fh.write, fh, text)
  pcall(fh.close, fh)

  -- Cooperative yield after IO
  if os.sleep then
    os.sleep(0)
  end

  if not writeOk then
    return false, tostring(writeErr)
  end

  return true, nil
end

--- Check if the current log file exceeds the rotation limit.
-- If so, rename current → .old and leave an empty file for new writes.
-- Uses filesystem.size if available, otherwise falls back to opening
-- in read mode and measuring.
function LogExporter:_checkRotation()
  local fileSize = self:_getFileSize(self._logPath)
  if not fileSize or fileSize < self._rotationSize then
    return  -- No rotation needed
  end

  -- Remove old backup if it exists
  self:_removeFile(self._logPathOld)

  -- Rename current → .old
  local ok = self:_renameFile(self._logPath, self._logPathOld)
  if ok then
    self._totalRotations = self._totalRotations + 1
  end
end

--- Get the size of a file in bytes.
-- Uses filesystem.size if available (OC API), otherwise reads file length.
-- @param path  string
-- @return number|nil  size in bytes, or nil if file doesn't exist
function LogExporter:_getFileSize(path)
  -- Prefer the OC filesystem.size API if injected
  if self._filesystem and self._filesystem.size then
    local ok, size = pcall(self._filesystem.size, path)
    if ok and size then
      return size
    end
  end

  -- Fallback: open and measure
  local io = self._ioProvider
  local ok, fh = pcall(io.open, path, "r")
  if not ok or not fh then
    return nil  -- File doesn't exist
  end

  local content = fh:read("*a")
  fh:close()
  return #content
end

--- Remove a file from disk.
-- @param path  string
-- @return boolean
function LogExporter:_removeFile(path)
  local io = self._ioProvider

  -- Try os.remove (OC filesystem)
  local ok = pcall(os.remove, path)
  if ok then
    return true
  end

  return false
end

--- Rename a file.
-- @param oldPath  string
-- @param newPath  string
-- @return boolean
function LogExporter:_renameFile(oldPath, newPath)
  local io = self._ioProvider

  -- Try os.rename (OC filesystem)
  local ok = pcall(os.rename, oldPath, newPath)
  if ok then
    return true
  end

  return false
end

return LogExporter
