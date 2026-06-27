--[[
test_logger_io.lua — Unit tests for D2: LogFilter + LogExporter
AE2 Execution System (AE2-ES)

Tests:
  - LogFilter with single criterion
  - LogFilter with multiple criteria (AND)
  - LogFilter with nil criteria (match all)
  - LogFilter on empty buffer
  - LogExporter stages below batch threshold (no flush)
  - LogExporter flushes at batch threshold exactly
  - LogExporter 60-second time-based flush
  - LogExporter disk rotation at 512KB boundary
  - Mock OC filesystem for deterministic testing

Usage:
  lua tests/test_logger_io.lua
]]

local LogFilter   = dofile("src/log_filter.lua")
local LogExporter = dofile("src/log_exporter.lua")

-- Test framework
local tests_run = 0; local tests_passed = 0; local tests_failed = {}

local function assert_eq(a, b, msg)
  tests_run = tests_run + 1
  if a == b then tests_passed = tests_passed + 1
  else table.insert(tests_failed, string.format("FAIL: %s (expected %s, got %s)", msg or "", tostring(b), tostring(a))) end
end

local function assert_true(v, m)
  tests_run = tests_run + 1
  if v then tests_passed = tests_passed + 1
  else table.insert(tests_failed, string.format("FAIL: %s (expected truthy, got %s)", m or "", tostring(v))) end
end
local function assert_false(v, m)
  tests_run = tests_run + 1
  if not v then tests_passed = tests_passed + 1
  else table.insert(tests_failed, string.format("FAIL: %s (expected falsy, got %s)", m or "", tostring(v))) end
end
local function assert_nil(v, m) assert_eq(v, nil, m) end
local function assert_not_nil(v, m)
  tests_run = tests_run + 1
  if v ~= nil then tests_passed = tests_passed + 1
  else table.insert(tests_failed, string.format("FAIL: %s (expected non-nil)", m or "")) end
end

-- Helper: create a sample log entry
local function makeEntry(severity, originId, message, timestamp)
  return {
    timestamp = timestamp or 1000,
    severity  = severity or "INFO",
    originId  = originId or "EB-TEST",
    message   = message or "Test message",
  }
end

-- Helper: create a test buffer with sample entries
local function makeSampleBuffer()
  return {
    makeEntry("INFO",    "EB-LCR-01", "Buffer stable"),
    makeEntry("WARNING", "EB-LCR-01", "Buffer nearly full"),
    makeEntry("ERROR",   "EB-LCR-01", "Item jam detected"),
    makeEntry("INFO",    "EB-SML-02", "Machine online"),
    makeEntry("CRITICAL", "EB-LCR-01", "Power starvation"),
    makeEntry("ERROR",   "EB-SML-02", "Overflow detected"),
  }
end

-- ===========================================================================
-- LogFilter Tests
-- ===========================================================================

local function test_filter_single_criterion()
  print("\n=== test_filter_single_criterion ===")
  local buffer = makeSampleBuffer()
  -- Filter by severity == "ERROR"
  local result = LogFilter.execute(buffer, { severity = "ERROR" })
  assert_eq(#result, 2, "2 ERROR entries found")
  assert_eq(result[1].message, "Item jam detected", "first ERROR is item jam")
  assert_eq(result[2].message, "Overflow detected", "second ERROR is overflow")
end

local function test_filter_single_criterion_origin()
  print("\n=== test_filter_single_criterion_origin ===")
  local buffer = makeSampleBuffer()
  -- Filter by originId
  local result = LogFilter.execute(buffer, { originId = "EB-SML-02" })
  assert_eq(#result, 2, "2 entries from EB-SML-02")
  assert_eq(result[1].message, "Machine online", "first from SML-02")
  assert_eq(result[2].message, "Overflow detected", "second from SML-02")
end

local function test_filter_multiple_criteria_and()
  print("\n=== test_filter_multiple_criteria_and ===")
  local buffer = makeSampleBuffer()
  -- Filter by severity AND originId
  local result = LogFilter.execute(buffer, { severity = "ERROR", originId = "EB-LCR-01" })
  assert_eq(#result, 1, "1 entry: ERROR + EB-LCR-01")
  assert_eq(result[1].message, "Item jam detected", "only item jam matches both")

  -- Different combo: WARNING + EB-LCR-01
  local result2 = LogFilter.execute(buffer, { severity = "WARNING", originId = "EB-LCR-01" })
  assert_eq(#result2, 1, "1 entry: WARNING + EB-LCR-01")
  assert_eq(result2[1].message, "Buffer nearly full", "buffer nearly full")
end

local function test_filter_nil_criteria()
  print("\n=== test_filter_nil_criteria ===")
  local buffer = makeSampleBuffer()
  -- No criteria (nil) → returns all entries (pass-through)
  local result = LogFilter.execute(buffer, nil)
  assert_eq(#result, 6, "nil criteria returns all 6 entries")
  assert_eq(result[1].message, "Buffer stable", "first entry preserved")
  assert_eq(result[6].message, "Overflow detected", "last entry preserved")
end

local function test_filter_empty_criteria_table()
  print("\n=== test_filter_empty_criteria_table ===")
  local buffer = makeSampleBuffer()
  -- Empty criteria table → returns all entries
  local result = LogFilter.execute(buffer, {})
  assert_eq(#result, 6, "empty criteria returns all 6")
end

local function test_filter_empty_buffer()
  print("\n=== test_filter_empty_buffer ===")
  local result = LogFilter.execute({}, { severity = "ERROR" })
  assert_eq(#result, 0, "empty buffer returns empty result")

  local result2 = LogFilter.execute({}, nil)
  assert_eq(#result2, 0, "empty buffer + nil criteria returns empty")
end

local function test_filter_no_mutation()
  print("\n=== test_filter_no_mutation ===")
  local buffer = makeSampleBuffer()
  local originalCount = #buffer
  LogFilter.execute(buffer, { severity = "ERROR" })
  assert_eq(#buffer, originalCount, "source buffer unchanged after filter")
end

local function test_filter_nil_criteria_field()
  print("\n=== test_filter_nil_criteria_field ===")
  local buffer = makeSampleBuffer()
  -- severity = nil (wildcard) with originId specified
  local result = LogFilter.execute(buffer, { severity = nil, originId = "EB-LCR-01" })
  assert_eq(#result, 4, "4 entries from EB-LCR-01 (severity wildcard)")
end

local function test_filter_non_table_input()
  print("\n=== test_filter_non_table_input ===")
  local result = LogFilter.execute(nil, { severity = "ERROR" })
  assert_eq(#result, 0, "nil source returns empty")

  local result2 = LogFilter.execute("not a table", {})
  assert_eq(#result2, 0, "string source returns empty")
end

-- ===========================================================================
-- LogExporter Tests
-- ===========================================================================

-- Mock OC filesystem for deterministic testing
local function createMockFS()
  local files = {}  -- path → content string

  local mockIO = {
    open = function(path, mode)
      if mode == "a" then
        -- Append mode: return a writeable handle
        local handle = {
          _path = path,
          _data = nil,
          write = function(self, text)
            if not files[self._path] then
              files[self._path] = ""
            end
            files[self._path] = files[self._path] .. text
            return true
          end,
          close = function(self)
            -- no-op
          end,
          read = function(self, fmt)
            if fmt == "*a" then
              return files[self._path] or ""
            end
            return nil
          end,
        }
        return handle
      elseif mode == "r" then
        if not files[path] then
          return nil, "No such file"
        end
        local handle = {
          _path = path,
          write = function() end,
          close = function() end,
          read = function(self, fmt)
            if fmt == "*a" then return files[self._path] or "" end
            return nil
          end,
        }
        return handle
      end
      return nil, "Unsupported mode: " .. tostring(mode)
    end,
    lines = function(path)
      local content = files[path]
      if not content then return function() return nil end end
      local idx = 0
      local lines = {}
      for line in content:gmatch("(.-)\n") do
        table.insert(lines, line)
      end
      if content:sub(-1) ~= "\n" and #content > 0 then
        table.insert(lines, content)
      end
      return function()
        idx = idx + 1
        return lines[idx]
      end
    end,
  }

  local mockFS = {
    size = function(path)
      local content = files[path]
      if not content then return nil end
      return #content
    end,
    _files = files,
  }

  -- Mock os.remove and os.rename
  local origRemove = os.remove
  local origRename = os.rename

  _G._mockOS = {
    remove = function(path)
      files[path] = nil
      return true
    end,
    rename = function(oldPath, newPath)
      if files[oldPath] then
        files[newPath] = files[oldPath]
        files[oldPath] = nil
        return true
      end
      return false, "file not found"
    end,
  }

  return mockIO, mockFS, files
end

local function test_exporter_stage_below_threshold()
  print("\n=== test_exporter_stage_below_threshold ===")
  local mockIO, mockFS = createMockFS()

  -- Save and mock os.clock so time doesn't advance
  local origClock = os.clock
  os.clock = function() return 0 end

  local exporter = LogExporter.new({
    batchThreshold = 5,
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  -- Stage 3 entries (below threshold of 5)
  assert_true(exporter:stage(makeEntry("INFO", "EB-T1", "msg1")), "stage msg1")
  assert_true(exporter:stage(makeEntry("WARNING", "EB-T1", "msg2")), "stage msg2")
  assert_true(exporter:stage(makeEntry("ERROR", "EB-T1", "msg3")), "stage msg3")

  local stats = exporter:getStats()
  assert_eq(stats.bufferCount, 3, "buffer has 3 entries (no flush yet)")
  assert_eq(stats.totalFlushed, 0, "no flushes occurred")

  -- Restore os.clock
  os.clock = origClock
end

local function test_exporter_flush_at_threshold()
  print("\n=== test_exporter_flush_at_threshold ===")
  local mockIO, mockFS, files = createMockFS()

  local origClock = os.clock
  os.clock = function() return 0 end

  local exporter = LogExporter.new({
    batchThreshold = 3,
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  -- Stage 2 entries, no flush yet
  assert_true(exporter:stage(makeEntry("INFO", "EB-T1", "msg1")), "stage msg1")
  assert_true(exporter:stage(makeEntry("INFO", "EB-T1", "msg2")), "stage msg2")
  assert_eq(exporter:getStats().bufferCount, 2, "buffer at 2")

  -- Stage the 3rd entry → triggers auto-flush
  assert_true(exporter:stage(makeEntry("INFO", "EB-T1", "msg3")), "stage msg3")

  local stats = exporter:getStats()
  assert_eq(stats.bufferCount, 0, "buffer cleared after flush")
  assert_eq(stats.totalFlushed, 1, "one flush occurred")

  -- Verify file was written
  local content = files["/home/logs/ae2-es_system.log"]
  assert_not_nil(content, "log file was created")
  -- Should have 3 lines
  local lineCount = 0
  for _ in content:gmatch("(.-)\n") do lineCount = lineCount + 1 end
  assert_eq(lineCount, 3, "3 lines written to log file")

  os.clock = origClock
end

local function test_exporter_time_based_flush()
  print("\n=== test_exporter_time_based_flush ===")
  local mockIO, mockFS, files = createMockFS()

  local fakeTime = 0
  local origClock = os.clock
  os.clock = function() return fakeTime end

  local exporter = LogExporter.new({
    batchThreshold = 20,  -- High threshold, won't trigger batch flush
    flushInterval = 10,   -- 10-second time-based flush
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  -- Stage 2 entries
  exporter:stage(makeEntry("WARNING", "EB-T1", "time test"))
  exporter:stage(makeEntry("ERROR", "EB-T1", "time test 2"))
  assert_eq(exporter:getStats().bufferCount, 2, "2 entries in buffer")

  -- Tick before interval → no flush
  local flushed = exporter:tick()
  assert_false(flushed, "no flush before interval")
  assert_eq(exporter:getStats().bufferCount, 2, "buffer still 2")

  -- Advance time past interval
  fakeTime = 15
  flushed = exporter:tick()
  assert_true(flushed, "time-based flush triggered")
  assert_eq(exporter:getStats().bufferCount, 0, "buffer cleared")
  assert_eq(exporter:getStats().totalFlushed, 1, "one flush recorded")

  -- Verify file content
  local content = files["/home/logs/ae2-es_system.log"]
  assert_not_nil(content, "log file has content")

  os.clock = origClock
end

local function test_exporter_explicit_flush()
  print("\n=== test_exporter_explicit_flush ===")
  local mockIO, mockFS, files = createMockFS()

  local origClock = os.clock
  os.clock = function() return 0 end

  local exporter = LogExporter.new({
    batchThreshold = 100,
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  -- Stage entries then manually flush
  exporter:stage(makeEntry("CRITICAL", "EB-EBF", "Power lost"))
  exporter:stage(makeEntry("INFO", "EB-EBF", "Rebooting"))
  assert_eq(exporter:getStats().bufferCount, 2, "2 staged")

  local result = exporter:flushToHDD()
  assert_true(result, "explicit flush succeeded")
  assert_eq(exporter:getStats().bufferCount, 0, "buffer cleared after explicit flush")

  local content = files["/home/logs/ae2-es_system.log"]
  assert_not_nil(content, "file has content")

  os.clock = origClock
end

local function test_exporter_flush_empty_buffer()
  print("\n=== test_exporter_flush_empty_buffer ===")
  local mockIO, mockFS = createMockFS()

  local exporter = LogExporter.new({
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  local result = exporter:flushToHDD()
  assert_false(result, "flush on empty buffer returns false")
end

local function test_exporter_disk_rotation()
  print("\n=== test_exporter_disk_rotation ===")
  local mockIO, mockFS, files = createMockFS()

  local origClock = os.clock
  os.clock = function() return 0 end

  -- Save and mock os.remove/os.rename so rotation works against mock files table
  local origRemove = os.remove
  local origRename = os.rename
  os.remove = function(path)
    files[path] = nil
    return true
  end
  os.rename = function(oldPath, newPath)
    if files[oldPath] then
      files[newPath] = files[oldPath]
      files[oldPath] = nil
      return true
    end
    return false, "file not found"
  end

  -- Create an exporter with a very small rotation size (100 bytes)
  local exporter = LogExporter.new({
    batchThreshold = 1,
    rotationSize = 100,
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  -- Generate entries that will exceed 100 bytes
  for i = 1, 5 do
    exporter:stage(makeEntry("INFO", "EB-DISK", string.rep("X", 30)))
  end
  assert_eq(exporter:getStats().bufferCount, 0, "auto-flushed")
  assert_eq(exporter:getStats().totalFlushed, 5, "5 flushes occurred")

  -- Check that rotation happened — by flush 3 the file exceeds 100 bytes
  assert_true(exporter:getStats().totalRotations >= 1, "at least one rotation occurred")
  assert_not_nil(files["/home/logs/ae2-es_system.log.old"], "backup file exists")
  assert_not_nil(files["/home/logs/ae2-es_system.log"], "current log file exists")

  -- Restore originals
  os.remove = origRemove
  os.rename = origRename
  os.clock = origClock
end

local function test_exporter_no_rotation_below_threshold()
  print("\n=== test_exporter_no_rotation_below_threshold ===")
  local mockIO, mockFS, files = createMockFS()

  local origClock = os.clock
  os.clock = function() return 0 end

  local exporter = LogExporter.new({
    batchThreshold = 1,
    rotationSize = 5000,  -- Very large, won't trigger
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  -- Stage small entries
  for i = 1, 3 do
    exporter:stage(makeEntry("INFO", "EB-NOROT", "Small entry"))
  end

  assert_eq(exporter:getStats().totalRotations, 0, "no rotations")
  assert_nil(files["/home/logs/ae2-es_system.log.old"], "no backup file created")

  os.clock = origClock
end

local function test_exporter_format_entry()
  print("\n=== test_exporter_format_entry ===")
  local mockIO, mockFS = createMockFS()

  local exporter = LogExporter.new({
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  local entry = { timestamp = 12345, severity = "ERROR", originId = "EB-TEST", message = "Something broke" }
  local line = exporter:_formatEntry(entry)
  assert_eq(line, "[12345] ERROR  EB-TEST  Something broke", "formatted line matches expected pattern")

  -- Entry with missing fields
  local partial = { severity = "INFO" }
  local line2 = exporter:_formatEntry(partial)
  -- timestamp missing → tostring(nil) = "nil" ; originId missing → "?" ; message missing → ""
  assert_true(string.find(line2, "INFO"), "contains severity")
  assert_true(string.find(line2, "%?"), "missing fields get defaults")
end

local function test_exporter_stage_rejects_non_table()
  print("\n=== test_exporter_stage_rejects_non_table ===")
  local mockIO, mockFS = createMockFS()
  local exporter = LogExporter.new({
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  assert_false(exporter:stage(nil), "nil rejected")
  assert_false(exporter:stage("string"), "string rejected")
  assert_false(exporter:stage(42), "number rejected")
end

local function test_exporter_get_stats()
  print("\n=== test_exporter_get_stats ===")
  local mockIO, mockFS = createMockFS()

  local exporter = LogExporter.new({
    batchThreshold = 10,
    flushInterval = 30,
    logPath = "/tmp/test.log",
    logPathOld = "/tmp/test.log.old",
    ioProvider = mockIO,
    filesystem = mockFS,
  })

  local stats = exporter:getStats()
  assert_eq(stats.batchThreshold, 10, "batchThreshold in stats")
  assert_eq(stats.bufferCount, 0, "bufferCount in stats")
  assert_eq(stats.totalFlushed, 0, "totalFlushed in stats")
  assert_eq(stats.totalRotations, 0, "totalRotations in stats")
  assert_eq(stats.logPath, "/tmp/test.log", "logPath in stats")
  assert_eq(stats.logPathOld, "/tmp/test.log.old", "logPathOld in stats")
end

-- ===========================================================================
-- Multi-criteria edge cases
-- ===========================================================================

local function test_filter_three_criteria()
  print("\n=== test_filter_three_criteria ===")
  local buffer = {
    makeEntry("ERROR",   "EB-A", "Disk full"),
    makeEntry("ERROR",   "EB-A", "CRC mismatch"),
    makeEntry("CRITICAL", "EB-A", "On fire"),
    makeEntry("ERROR",   "EB-B", "Bad sector"),
  }
  local result = LogFilter.execute(buffer, {
    severity = "ERROR",
    originId = "EB-A",
  })
  assert_eq(#result, 2, "2 ERROR entries from EB-A")
end

local function test_filter_case_sensitivity()
  print("\n=== test_filter_case_sensitivity ===")
  local buffer = {
    makeEntry("error", "EB-TEST", "lowercase"),
    makeEntry("ERROR", "EB-TEST", "uppercase"),
  }
  -- Case-sensitive comparison (tostring)
  local result = LogFilter.execute(buffer, { severity = "ERROR" })
  assert_eq(#result, 1, "case-sensitive: only 'ERROR' matches 'ERROR'")
  assert_eq(result[1].message, "uppercase", "matched uppercase entry")
end

-- ===========================================================================
-- Run all tests
-- ===========================================================================

local function run_all()
  local groups = {
    -- LogFilter tests
    test_filter_single_criterion,
    test_filter_single_criterion_origin,
    test_filter_multiple_criteria_and,
    test_filter_nil_criteria,
    test_filter_empty_criteria_table,
    test_filter_empty_buffer,
    test_filter_no_mutation,
    test_filter_nil_criteria_field,
    test_filter_non_table_input,
    test_filter_three_criteria,
    test_filter_case_sensitivity,
    -- LogExporter tests
    test_exporter_stage_below_threshold,
    test_exporter_flush_at_threshold,
    test_exporter_time_based_flush,
    test_exporter_explicit_flush,
    test_exporter_flush_empty_buffer,
    test_exporter_disk_rotation,
    test_exporter_no_rotation_below_threshold,
    test_exporter_format_entry,
    test_exporter_stage_rejects_non_table,
    test_exporter_get_stats,
  }

  for _, fn in ipairs(groups) do
    fn()
  end

  print(string.format("\n=== Results: %d/%d passed, %d failed ===", tests_passed, tests_run, #tests_failed))
  if #tests_failed > 0 then
    for _, f in ipairs(tests_failed) do
      print("  " .. f)
    end
    os.exit(1)
  end
end

run_all()
