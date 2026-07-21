-- LogRingBuffer module
-- Fixed-size circular queue for the Global Logger system.
-- Stores LogEntry references in a pre-allocated buffer with
-- head/tail pointer arithmetic. No table allocation beyond
-- the initial buffer growth phase — reused slots.

local LogRingBuffer = {}
LogRingBuffer.__index = LogRingBuffer

local DEFAULT_MAX_SIZE = 500

-- Create a new LogRingBuffer
-- @param maxSize  number  maximum number of entries (default 500)
-- @return LogRingBuffer
function LogRingBuffer.new(maxSize)
  local self = {
    _maxSize = maxSize or DEFAULT_MAX_SIZE,
    _buffer  = {},
    _head    = 1,    -- next write position (1-based, cycles 1..maxSize)
    _tail    = 1,    -- oldest valid entry position
    _count   = 0,    -- number of valid entries currently stored
  }
  setmetatable(self, LogRingBuffer)
  return self
end

-- Append a log entry to the buffer.
-- When the buffer is full the oldest entry is overwritten.
-- @param logEntry  table  LogEntry (duck-typed)
function LogRingBuffer:append(logEntry)
  -- Overwrite slot at head
  self._buffer[self._head] = logEntry

  if self._count == self._maxSize then
    -- Buffer full: advance tail to the slot we just overwrote
    self._tail = (self._tail % self._maxSize) + 1
  else
    self._count = self._count + 1
  end

  -- Advance head for next write
  self._head = (self._head % self._maxSize) + 1
end

-- Return the most recent N entries in chronological order.
-- @param count  number  maximum entries to return
-- @return table  chronologically ordered array of log entries
function LogRingBuffer:getLatest(count)
  if self._count == 0 or count <= 0 then
    return {}
  end

  local actual = math.min(count, self._count)
  local result = {}
  -- Walk backwards from (head-1) to build chronological order
  local from = self._head - 1
  if from < 1 then from = self._maxSize end

  for i = 0, actual - 1 do
    local idx = from - i
    if idx < 1 then idx = idx + self._maxSize end
    -- Insert at front so result is chronological
    result[actual - i] = self._buffer[idx]
  end

  return result
end

-- Return all entries in chronological order.
-- @return table  array of log entries
function LogRingBuffer:getAll()
  if self._count == 0 then
    return {}
  end

  local result = {}
  local idx = self._tail
  for i = 1, self._count do
    result[i] = self._buffer[idx]
    idx = (idx % self._maxSize) + 1
  end
  return result
end

-- Current number of entries in the buffer.
-- @return number
function LogRingBuffer:count()
  return self._count
end

-- Maximum capacity of the buffer.
-- @return number
function LogRingBuffer:maxSize()
  return self._maxSize
end

-- Reset the buffer to empty state.
-- Existing entries are not explicitly cleared (references held
-- by callers are their responsibility); internal pointers reset.
function LogRingBuffer:clear()
  self._buffer = {}
  self._head  = 1
  self._tail  = 1
  self._count = 0
end

return LogRingBuffer
