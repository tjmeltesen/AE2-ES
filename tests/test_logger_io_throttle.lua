-- test_logger_io_throttle.lua
-- D4: Global Logger — I/O Throttling verification tests
--
-- Validates LogExporter I/O behavior:
--   1. Batch threshold: flush delayed until batchThreshold reached
--   2. Count-based flush: increments trigger exactly at threshold multiples
--   3. Time-based flush: idle timer triggers flush at 60 seconds
--   4. Disk rotation: 512KB boundary creates .old file, starts new file
--   5. Combined batch+time: batch threshold takes priority over timer
--   6. Force flush: manual flush() resets counters
--
-- Uses mock clock and mock filesystem for deterministic, headless testing.
-- The LogExporter implementation is modelled as a stub matching the spec;
-- tests serve as executable specification.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

-- ===========================================================================
-- Deterministic mocks: clock + filesystem
-- ===========================================================================

local mockClock = 1000000.0     -- mock epoch seconds
local mockFs = { files = {} }   -- mock filesystem: path -> content

--- Reset all mocks to initial state.
local function resetMocks()
  mockClock = 1000000.0
  mockFs = { files = {} }
end

--- Advance mock clock.
-- @param seconds number
local function advanceClock(seconds)
  mockClock = mockClock + seconds
end

--- Mock os.time() and os.epoch() for deterministic testing.
os.time = function() return math.floor(mockClock) end
os.epoch = function() return math.floor(mockClock * 1000) end

-- ===========================================================================
-- LogExporter Stub — matches the spec API
-- ===========================================================================

local LogExporter = {}
LogExporter.__index = LogExporter

function LogExporter.new(config)
  local self = setmetatable({}, LogExporter)
  config = config or {}

  self.batchThreshold = config.batchThreshold or 20
  self.timeThreshold  = config.timeThreshold or 60      -- seconds
  self.diskMaxSize    = config.diskMaxSize or 524288     -- 512KB default
  self.basePath       = config.basePath or "/var/log/ae2es/logger"

  -- Internal state
  self._buffer         = {}       -- pending entries staged for flush
  self._flushCount     = 0        -- number of flushes performed
  self._lastFlushTime  = mockClock -- timestamp of last flush
  self._currentFile    = self.basePath .. ".log"
  self._currentSize    = 0        -- bytes written to current file
  self._diskRotations  = 0        -- number of .old files created
  self._rotationFiles  = {}       -- tracks .old file paths
  self._flushCallLog   = {}       -- detailed flush call log

  return self
end

--- Stage a log entry for batched flush.
-- @param entry table  log entry to buffer
function LogExporter:stage(entry)
  table.insert(self._buffer, entry)
end

--- Get current pending count.
-- @return number
function LogExporter:pending()
  return #self._buffer
end

--- Attempt a batched flush. Flushes only when:
--   1. Pending count >= batchThreshold, OR
--   2. Time since last flush >= timeThreshold (and buffer is non-empty)
-- @param force boolean  if true, flush regardless of thresholds
-- @return boolean  true if flush occurred
function LogExporter:flush(force)
  local now = mockClock
  local pendingCount = #self._buffer
  local timeSinceLast = now - self._lastFlushTime

  local shouldFlush = force
    or pendingCount >= self.batchThreshold
    or (pendingCount > 0 and timeSinceLast >= self.timeThreshold)

  if not shouldFlush then
    return false
  end

  -- Perform flush: write entries to "disk"
  local data = ""
  for _, entry in ipairs(self._buffer) do
    -- Serialize entry (simplified: concatenate message + newline)
    data = data .. (entry.message or "") .. "\n"
  end

  -- Check disk rotation before writing
  if self._currentSize + #data > self.diskMaxSize then
    self:_rotateDisk()
  end

  -- Write to filesystem
  local existing = mockFs.files[self._currentFile] or ""
  mockFs.files[self._currentFile] = existing .. data
  self._currentSize = self._currentSize + #data

  -- Log the flush
  self._flushCount = self._flushCount + 1
  self._lastFlushTime = now
  table.insert(self._flushCallLog, {
    time = now,
    entries = pendingCount,
    dataSize = #data,
    file = self._currentFile,
    force = force or false,
  })

  -- Clear buffer
  self._buffer = {}

  return true
end

--- Internal: rotate disk file.
function LogExporter:_rotateDisk()
  local oldPath = self._currentFile .. ".old"
  if mockFs.files[self._currentFile] then
    mockFs.files[oldPath] = mockFs.files[self._currentFile]
    self._rotationFiles[oldPath] = true
  end
  mockFs.files[self._currentFile] = nil
  self._diskRotations = self._diskRotations + 1
  self._currentSize = 0
end

--- Force immediate flush.
-- @return boolean true
function LogExporter:forceFlush()
  return self:flush(true)
end

--- Check if a file exists in the mock filesystem.
-- @param path string
-- @return boolean
function LogExporter:fileExists(path)
  return mockFs.files[path] ~= nil
end

--- Get file size on "disk".
-- @param path string
-- @return number  bytes
function LogExporter:fileSize(path)
  local content = mockFs.files[path]
  return content and #content or 0
end

--- Get total flush calls made.
-- @return number
function LogExporter:totalFlushes()
  return self._flushCount
end

--- Reset flush counter (for test isolation).
function LogExporter:resetCounters()
  self._flushCount = 0
  self._flushCallLog = {}
  self._diskRotations = 0
  self._rotationFiles = {}
end

-- ===========================================================================
-- Helper: create a simple log entry for staging
-- ===========================================================================

local function stageEntry(exporter, id, msgLen)
  msgLen = msgLen or 50
  local msg = string.format("log-%05d-", id) .. string.rep("x", msgLen)
  exporter:stage({ message = msg, timestamp = mockClock, id = id })
end

-- ===========================================================================
-- Test Group 1: Batch Threshold — Count-Based Flushing
-- ===========================================================================

-- Test 1.1: Below threshold — flush not triggered
Assert.startTest("Batch threshold: 15 entries below 20 = 0 flushes")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20 })
  for i = 1, 15 do
    stageEntry(exp, i, 30)
  end
  Assert.equal(15, exp:pending(), "15 entries staged")

  local didFlush = exp:flush()
  Assert.isFalse(didFlush, "flush() returns false below threshold")
  Assert.equal(0, exp:totalFlushes(), "0 flushes performed")
  Assert.equal(15, exp:pending(), "Pending entries preserved")
end
Assert.endTest()

-- Test 1.2: Exactly at threshold — flush triggered
Assert.startTest("Batch threshold: 20 entries at 20 = exactly 1 flush")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20 })
  for i = 1, 15 do
    stageEntry(exp, i, 30)
  end
  exp:flush()  -- no-op
  Assert.equal(0, exp:totalFlushes(), "0 flushes at 15")

  for i = 16, 20 do
    stageEntry(exp, i, 30)
  end
  local didFlush = exp:flush()
  Assert.isTrue(didFlush, "flush() returns true at threshold")
  Assert.equal(1, exp:totalFlushes(), "Exactly 1 flush performed")
  Assert.equal(0, exp:pending(), "Buffer emptied after flush")
end
Assert.endTest()

-- Test 1.3: Multiple threshold multiples
Assert.startTest("Batch threshold: 45 entries = 2 flushes (20+20+5 pending)")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20 })

  -- Stage 45 entries
  for i = 1, 45 do
    stageEntry(exp, i, 20)
    exp:flush()  -- check after each entry
  end

  -- Should have flushed twice (at 20 and 40)
  Assert.equal(2, exp:totalFlushes(), "2 flushes at multiples of 20")
  Assert.equal(5, exp:pending(), "5 entries remain pending")
end
Assert.endTest()

-- Test 1.4: Repeated staging + flush cycles
Assert.startTest("Batch threshold: 3 flush cycles of 20 entries each")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20 })

  for cycle = 1, 3 do
    for i = 1, 20 do
      stageEntry(exp, (cycle - 1) * 20 + i, 10)
    end
    exp:flush()
    Assert.equal(cycle, exp:totalFlushes(),
      string.format("Cycle %d: total flushes = %d", cycle, cycle))
    Assert.equal(0, exp:pending(), "Buffer empty after each cycle flush")
  end
end
Assert.endTest()

-- ===========================================================================
-- Test Group 2: Time-Based Flushing
-- ===========================================================================

-- Test 2.1: Under time threshold — no flush
Assert.startTest("Time-based: 5 entries, 30 seconds elapsed = no flush")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  for i = 1, 5 do
    stageEntry(exp, i, 20)
  end
  Assert.equal(5, exp:pending())

  advanceClock(30)  -- 30 seconds elapsed
  local didFlush = exp:flush()
  Assert.isFalse(didFlush, "No flush at 30s (under 60s threshold)")
  Assert.equal(0, exp:totalFlushes())
end
Assert.endTest()

-- Test 2.2: At time threshold — flush triggered
Assert.startTest("Time-based: 5 entries, 60 seconds elapsed = flush")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  for i = 1, 5 do
    stageEntry(exp, i, 20)
  end

  advanceClock(60)  -- exactly at threshold
  local didFlush = exp:flush()
  Assert.isTrue(didFlush, "Flush triggered at exactly 60 seconds")
  Assert.equal(1, exp:totalFlushes(), "1 flush performed")
  Assert.equal(0, exp:pending(), "Buffer emptied")
end
Assert.endTest()

-- Test 2.3: Past time threshold — flush triggered
Assert.startTest("Time-based: 5 entries, 61 seconds elapsed = flush")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  for i = 1, 5 do
    stageEntry(exp, i, 20)
  end

  advanceClock(61)  -- past threshold by 1 second
  local didFlush = exp:flush()
  Assert.isTrue(didFlush, "Flush triggered at 61 seconds (past threshold)")
  Assert.equal(1, exp:totalFlushes())
  Assert.equal(0, exp:pending())
end
Assert.endTest()

-- Test 2.4: Time-based with empty buffer — no flush
Assert.startTest("Time-based: empty buffer past threshold = no flush")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  -- No entries staged
  advanceClock(120)  -- well past threshold
  local didFlush = exp:flush()
  Assert.isFalse(didFlush, "No flush with empty buffer even past time threshold")
  Assert.equal(0, exp:totalFlushes())
end
Assert.endTest()

-- Test 2.5: Timer resets after flush
Assert.startTest("Time-based: flush resets timer, second flush needs another 60s")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  -- Stage 5 entries, advance 60s, flush
  for i = 1, 5 do
    stageEntry(exp, i, 20)
  end
  advanceClock(60)
  exp:flush()
  Assert.equal(1, exp:totalFlushes())

  -- Stage 5 more, advance only 30s — no flush
  for i = 6, 10 do
    stageEntry(exp, i, 20)
  end
  advanceClock(30)
  local didFlush = exp:flush()
  Assert.isFalse(didFlush, "No flush at 30s after timer reset")

  -- Advance another 30s — now 60s total since last flush
  advanceClock(30)
  didFlush = exp:flush()
  Assert.isTrue(didFlush, "Flush after another 60s since last")
  Assert.equal(2, exp:totalFlushes())
end
Assert.endTest()

-- ===========================================================================
-- Test Group 3: Batch Priority over Time
-- ===========================================================================

-- Test 3.1: Batch threshold reached before time — batch wins
Assert.startTest("Batch > Time: 20 entries under 60s = batch flush, not time")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  for i = 1, 20 do
    stageEntry(exp, i, 20)
  end
  advanceClock(5)  -- only 5 seconds passed
  local didFlush = exp:flush()
  Assert.isTrue(didFlush, "Flush triggered by batch at 5 seconds")
  Assert.equal(1, exp:totalFlushes())
end
Assert.endTest()

-- Test 3.2: Flush purges buffer, time timer resets
Assert.startTest("After batch flush: next flush needs new batch or 60s")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  -- Batch flush
  for i = 1, 20 do
    stageEntry(exp, i, 20)
  end
  exp:flush()
  Assert.equal(1, exp:totalFlushes())

  -- Stage 5 entries, advance 30s — no flush (neither threshold met)
  for i = 1, 5 do
    stageEntry(exp, i, 20)
  end
  advanceClock(30)
  Assert.isFalse(exp:flush(), "No flush: under batch threshold, under time threshold")

  -- Advance to 60s — time flush
  advanceClock(30)
  Assert.isTrue(exp:flush(), "Flush at 60s after batch")
  Assert.equal(2, exp:totalFlushes())
end
Assert.endTest()

-- ===========================================================================
-- Test Group 4: Disk Rotation at 512KB Boundary
-- ===========================================================================

-- Test 4.1: Under disk limit — no rotation
Assert.startTest("Disk rotation: under 512KB — no .old file created")
do
  resetMocks()
  local exp = LogExporter.new({
    batchThreshold = 10,
    diskMaxSize = 524288,  -- 512KB
  })

  -- Write 100KB of logs (well under 512KB)
  for batch = 1, 10 do
    for i = 1, 10 do
      -- 1000 bytes per entry × 10 = 10KB per batch
      stageEntry(exp, (batch - 1) * 10 + i, 980)
    end
    exp:flush()
  end

  Assert.equal(10, exp:totalFlushes(), "10 flushes performed")
  Assert.equal(0, exp._diskRotations, "No disk rotations")
  Assert.isTrue(exp:fileExists(exp._currentFile), "Current log file exists")
  Assert.isFalse(exp:fileExists(exp._currentFile .. ".old"), "No .old file created")
end
Assert.endTest()

-- Test 4.2: At disk limit — rotation triggered
Assert.startTest("Disk rotation: writing 513KB past 512KB = .old file created")
do
  resetMocks()
  local exp = LogExporter.new({
    batchThreshold = 1,        -- flush every entry for precise size control
    diskMaxSize = 524288,     -- 512KB
  })

  local bytesWritten = 0
  local entryId = 0

  -- Write entries of ~10KB each. To write ~513KB: 52 entries of 10KB.
  local entrySize = 10000
  local expectedEntries = math.ceil(524288 / entrySize) + 1  -- ~53 entries to exceed

  for i = 1, expectedEntries do
    entryId = entryId + 1
    stageEntry(exp, entryId, entrySize)
    exp:flush()
    bytesWritten = bytesWritten + entrySize + 1  -- +1 for newline
    if exp._diskRotations > 0 then break end
  end

  Assert.isTrue(bytesWritten > 524288,
    string.format("Total bytes written (%d) exceeds 512KB", bytesWritten))
  Assert.isTrue(exp._diskRotations >= 1,
    string.format("Disk rotation occurred: %d rotations", exp._diskRotations))
  Assert.isTrue(exp:fileExists(exp._currentFile .. ".old"),
    ".old file created on rotation")
  Assert.isTrue(exp:fileExists(exp._currentFile),
    "New current file created after rotation")

  -- .old file should contain the old content (up to 512KB)
  local oldSize = exp:fileSize(exp._currentFile .. ".old")
  Assert.isTrue(oldSize > 0, ".old file has content")
  Assert.isTrue(oldSize <= 524288 + entrySize + 1,
    string.format(".old file size (%d) roughly <= 512KB", oldSize))
end
Assert.endTest()

-- Test 4.3: Write exactly 512KB + 1 byte — rotation at boundary
Assert.startTest("Disk rotation: 512KB + 1 byte triggers exactly 1 rotation")
do
  resetMocks()
  local exp = LogExporter.new({
    batchThreshold = 1,
    diskMaxSize = 512 * 1024,  -- 524288
  })

  -- Write exactly 524288 bytes (not enough to trigger rotation on its own
  -- since rotation happens when _currentSize + newData > diskMaxSize)
  -- Write a first chunk of 500KB then a second of 13KB to push past
  local chunk1 = 500 * 1024
  stageEntry(exp, 0, chunk1 - 1)  -- -1 for newline overhead: message(500KB) + \n
  exp:flush()
  Assert.equal(0, exp._diskRotations, "No rotation after 500KB")

  local oldFile = exp._currentFile .. ".old"
  Assert.isFalse(exp:fileExists(oldFile), "No .old file yet")

  -- Write 13KB more (total 513KB > 512KB) — should rotate
  local chunk2 = 13 * 1024
  stageEntry(exp, 1, chunk2 - 1)
  exp:flush()
  Assert.equal(1, exp._diskRotations, "1 rotation after exceeding 512KB")
  Assert.isTrue(exp:fileExists(oldFile), ".old file created")
end
Assert.endTest()

-- Test 4.4: Multiple rotations across heavy writes
Assert.startTest("Disk rotation: 3MB of logs = 6+ rotations at 512KB")
do
  resetMocks()
  local exp = LogExporter.new({
    batchThreshold = 1,
    diskMaxSize = 524288,
  })

  -- Write 3MB worth of logs in 10KB chunks
  local totalWritten = 0
  local targetBytes = 3 * 1024 * 1024  -- 3MB
  local entryId = 0
  local entrySize = 10000

  while totalWritten < targetBytes do
    entryId = entryId + 1
    stageEntry(exp, entryId, entrySize)
    exp:flush()
    totalWritten = totalWritten + entrySize + 1  -- +newline
  end

  -- At 512KB per file, 3MB should produce at least 5 rotations
  -- (3MB / 512KB = 6, minus the first file = 5 rotations)
  Assert.isTrue(exp._diskRotations >= 5,
    string.format("At least 5 rotations for 3MB (got %d)", exp._diskRotations))
  Assert.isTrue(exp:fileExists(exp._currentFile), "Final log file exists")
  Assert.isTrue(exp:fileExists(exp._currentFile .. ".old"),
    "Most recent .old file exists")
end
Assert.endTest()

-- ===========================================================================
-- Test Group 5: Force Flush
-- ===========================================================================

-- Test 5.1: Force flush ignores thresholds
Assert.startTest("Force flush: 3 entries force-flushed regardless of batch/time")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  for i = 1, 3 do
    stageEntry(exp, i, 20)
  end

  -- Only 3 entries, no time elapsed — should not auto-flush
  Assert.isFalse(exp:flush(), "Auto-flush returns false at 3 entries")

  -- Force flush
  local didFlush = exp:forceFlush()
  Assert.isTrue(didFlush, "Force flush succeeds")
  Assert.equal(1, exp:totalFlushes(), "1 flush performed")
  Assert.equal(0, exp:pending(), "Buffer emptied")
end
Assert.endTest()

-- Test 5.2: Force flush on empty buffer is safe
Assert.startTest("Force flush: empty buffer is no-op")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  local didFlush = exp:forceFlush()
  Assert.isTrue(didFlush, "Force flush on empty buffer succeeds (no-op)")
  Assert.equal(1, exp:totalFlushes(), "Counted as flush")
  Assert.equal(0, exp:pending())
end
Assert.endTest()

-- ===========================================================================
-- Test Group 6: Combined Scenarios
-- ===========================================================================

-- Test 6.1: Normal lifecycle: stage → accumulate → batch flush → repeat
Assert.startTest("Lifecycle: 3 cycles of stage+flush, counters consistent")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20 })

  for cycle = 1, 3 do
    for i = 1, 20 do
      stageEntry(exp, cycle * 100 + i, 30)
    end
    local didFlush = exp:flush()
    Assert.isTrue(didFlush, string.format("Cycle %d: flush triggered", cycle))
    Assert.equal(cycle, exp:totalFlushes(), string.format("Cycle %d: total flushes", cycle))
    Assert.equal(0, exp:pending(), string.format("Cycle %d: buffer empty", cycle))
  end

  -- Verify written data exists on "disk"
  Assert.isTrue(exp:fileExists(exp._currentFile), "Log file exists after cycles")
  Assert.isTrue(exp:fileSize(exp._currentFile) > 0, "Log file has content")
end
Assert.endTest()

-- Test 6.2: Mixed batch + time with real-world intervals
Assert.startTest("Mixed: batch-only then time-only, counters independent")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  -- First: batch flush
  for i = 1, 20 do
    stageEntry(exp, i, 30)
  end
  advanceClock(10)
  exp:flush()
  Assert.equal(1, exp:totalFlushes(), "Flush 1: batch")

  -- Second: time flush
  for i = 1, 5 do
    stageEntry(exp, i, 30)
  end
  advanceClock(65)  -- past threshold since last flush (which was at t=10)
  exp:flush()
  Assert.equal(2, exp:totalFlushes(), "Flush 2: time-based")

  -- Third: batch flush (rapid accumulation)
  for i = 1, 20 do
    stageEntry(exp, i, 30)
  end
  exp:flush()
  Assert.equal(3, exp:totalFlushes(), "Flush 3: batch")
end
Assert.endTest()

-- Test 6.3: Idle period: no data, time passes, no spurious flushes
Assert.startTest("Idle: 300 seconds with no data = 0 flushes")
do
  resetMocks()
  local exp = LogExporter.new({ batchThreshold = 20, timeThreshold = 60 })

  advanceClock(300)  -- 5 minutes idle
  local didFlush = exp:flush()
  Assert.isFalse(didFlush, "No flush on idle (empty buffer)")
  Assert.equal(0, exp:totalFlushes())
end
Assert.endTest()
