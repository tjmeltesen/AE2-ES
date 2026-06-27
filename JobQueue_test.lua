-- JobQueue_test.lua
-- Unit tests for AE2-ES Module A4: JobQueue
-- Designed for OC Emulator (Tier 1) or standard Lua 5.2/5.3
--
-- Usage:
--   lua JobQueue_test.lua                  -- run all tests

local JobQueue = dofile("JobQueue.lua")

local tests_run = 0; local tests_passed = 0; local tests_failed = {}

local function assert_eq(a, b, msg)
  tests_run = tests_run + 1
  if a == b then tests_passed = tests_passed + 1
  else table.insert(tests_failed, string.format("FAIL: %s (expected %s, got %s)", msg or "", tostring(b), tostring(a))) end
end
local function assert_true(v, m) assert_eq(v, true, m) end
local function assert_false(v, m) assert_eq(v, false, m) end
local function assert_nil(v, m) assert_eq(v, nil, m) end

local function makeJob(id, priority, status, createdAt)
  return { id = id or tostring(math.random()), priority = priority or 0, status = status or "PENDING", createdAt = createdAt or os.time(), updatedAt = createdAt or os.time() }
end

local function test_new()
  print("\n=== test_new ===")
  local q = JobQueue.new()
  assert_eq(q:length(), 0, "new queue length is 0")
  assert_eq(q:getMaxSize(), 64, "default maxSize = 64")
  assert_false(q:isFull(), "new queue not full")
  local q2 = JobQueue.new(3)
  assert_eq(q2:getMaxSize(), 3, "custom maxSize = 3")
end

local function test_push()
  print("\n=== test_push ===")
  local q = JobQueue.new()
  assert_true(q:push(makeJob("j1", 1)), "push j1 (priority 1)")
  assert_true(q:push(makeJob("j2", 2)), "push j2 (priority 2)")
  assert_eq(q:length(), 2, "length = 2 after 2 pushes")
  assert_false(q:push(nil), "nil rejected")
  assert_false(q:push({}), "no-id table rejected")
  local q2 = JobQueue.new(2)
  assert_true(q2:push(makeJob("a")), "push to 2-slot queue")
  assert_true(q2:push(makeJob("b")), "push second")
  assert_false(q2:push(makeJob("c")), "third rejected (full)")
  assert_eq(q2:length(), 2, "still at capacity")
end

local function test_push_priority_order()
  print("\n=== test_push_priority_order ===")
  local q = JobQueue.new()
  q:push(makeJob("low", 1)); q:push(makeJob("high", 10))
  q:push(makeJob("medium", 5)); q:push(makeJob("top", 20))
  local snap = q:peek()
  assert_eq(snap[1].id, "top", "first = priority 20")
  assert_eq(snap[2].id, "high", "second = priority 10")
  assert_eq(snap[3].id, "medium", "third = priority 5")
  assert_eq(snap[4].id, "low", "fourth = priority 1")
end

local function test_push_fifo_for_equal_priority()
  print("\n=== test_push_fifo_equal_priority ===")
  local q = JobQueue.new()
  q:push(makeJob("first", 5)); q:push(makeJob("second", 5)); q:push(makeJob("third", 5))
  local snap = q:peek()
  assert_eq(snap[1].id, "first", "FIFO: first is first")
  assert_eq(snap[2].id, "second", "FIFO: second is second")
  assert_eq(snap[3].id, "third", "FIFO: third is third")
end

local function test_popNextAvailable()
  print("\n=== test_popNextAvailable ===")
  local q = JobQueue.new()
  q:push(makeJob("j1", 5)); q:push(makeJob("j2", 3)); q:push(makeJob("j3", 5))
  local job = q:popNextAvailable()
  assert_eq(job.id, "j1", "popNextAvailable returns highest priority, oldest")
  assert_eq(job.status, "DISPATCHED", "status set to DISPATCHED")
  job = q:popNextAvailable(); assert_eq(job.id, "j3", "remaining highest priority (j3 over j2)")
  job = q:popNextAvailable(); assert_eq(job.id, "j2", "last job popped")
  job = q:popNextAvailable(); assert_nil(job, "nil on empty queue")
end

local function test_popNextAvailable_skips_dispatched()
  print("\n=== test_popNextAvailable_skips_dispatched ===")
  local q = JobQueue.new()
  q:push(makeJob("a", 5)); q:push(makeJob("b", 5)); q:push(makeJob("c", 5))
  local a = q:popNextAvailable(); assert_eq(a.id, "a", "first pop gets 'a'")
  local b = q:popNextAvailable(); assert_eq(b.id, "b", "second pop gets 'b'")
end

local function test_popNextAvailable_skips_non_pending()
  print("\n=== test_popNextAvailable_skips_non_pending ===")
  local q = JobQueue.new()
  q:push(makeJob("a", 5)); q:push(makeJob("b", 5, "PROCESSING")); q:push(makeJob("c", 5))
  local job = q:popNextAvailable(); assert_eq(job.id, "a", "skips PROCESSING job, returns next PENDING")
end

local function test_validateQueue()
  print("\n=== test_validateQueue ===")
  local q = JobQueue.new(); q:setStaleTimeout(10)
  local now = os.time()
  q:push(makeJob("fresh", 1, "PENDING", now))
  q:push(makeJob("old", 1, "PENDING", now - 20))
  q:push(makeJob("term", 1, "COMPLETED", now - 999))
  local removed = q:validateQueue(now)
  assert_eq(removed, 1, "1 stale job removed")
  assert_eq(q:length(), 2, "2 remain: fresh + terminal")
  local snap = q:peek()
  assert_eq(snap[1].id, "fresh", "fresh remains")
  assert_eq(snap[2].id, "term", "COMPLETED job remains (not stale)")
end

local function test_validateQueue_uses_job_isStale()
  print("\n=== test_validateQueue_uses_job_isStale ===")
  local q = JobQueue.new()
  local called = false
  local job = makeJob("custom", 1, "PENDING", os.time())
  job.isStale = function(_, _) called = true; return true end
  q:push(job)
  local removed = q:validateQueue(); assert_true(called, "custom isStale was called")
  assert_eq(removed, 1, "job removed via custom isStale")
end

local function test_maxSize_limit()
  print("\n=== test_maxSize_limit ===")
  local q = JobQueue.new(2)
  assert_true(q:push(makeJob("a")), "push to limit")
  assert_true(q:push(makeJob("b")), "at limit")
  assert_eq(q:isFull(), true, "isFull reports true")
  assert_false(q:push(makeJob("c")), "push beyond limit rejected")
  assert_eq(q:length(), 2, "length unchanged")
end

local function test_cancel()
  print("\n=== test_cancel ===")
  local q = JobQueue.new()
  q:push(makeJob("x", 1)); q:push(makeJob("y", 1)); q:push(makeJob("z", 1))
  assert_true(q:cancel("y"), "cancel existing job")
  assert_eq(q:length(), 2, "length decreased")
  local snap = q:peek(); assert_eq(snap[1].id, "x"); assert_eq(snap[2].id, "z")
  assert_false(q:cancel("nonexistent"), "cancel non-existent returns false")
end

local function test_updateStatus()
  print("\n=== test_updateStatus ===")
  local q = JobQueue.new()
  q:push(makeJob("j1")); q:push(makeJob("j2"))
  assert_true(q:updateStatus("j1", "PROCESSING"), "updateStatus returns true")
  local snap = q:peek(); assert_eq(snap[1].status, "PROCESSING", "status changed")
  assert_false(q:updateStatus("nope", "FAULTED"), "non-existent returns false")
end

local function test_clear()
  print("\n=== test_clear ===")
  local q = JobQueue.new()
  q:push(makeJob("a")); q:push(makeJob("b"))
  assert_eq(q:length(), 2, "before clear")
  q:clear(); assert_eq(q:length(), 0, "after clear")
  assert_nil(q:popNextAvailable(), "pop after clear returns nil")
end

local function test_iter()
  print("\n=== test_iter ===")
  local q = JobQueue.new()
  q:push(makeJob("i1")); q:push(makeJob("i2")); q:push(makeJob("i3"))
  local count = 0; for _ in q:iter() do count = count + 1 end
  assert_eq(count, 3, "iterator covers all 3 jobs")
end

local function test_stale_skipped_in_pop()
  print("\n=== test_stale_skipped_in_pop ===")
  local q = JobQueue.new(); q:setStaleTimeout(10)
  local now = os.time()
  q:push(makeJob("stale", 10, "PENDING", now - 20))
  q:push(makeJob("fresh", 1, "PENDING", now))
  local job = q:popNextAvailable(); assert_eq(job.id, "fresh", "popNextAvailable skips stale jobs, returns fresh")
end

local function run_all()
  local groups = { test_new, test_push, test_push_priority_order, test_push_fifo_for_equal_priority, test_popNextAvailable, test_popNextAvailable_skips_dispatched, test_popNextAvailable_skips_non_pending, test_validateQueue, test_validateQueue_uses_job_isStale, test_maxSize_limit, test_cancel, test_updateStatus, test_clear, test_iter, test_stale_skipped_in_pop }
  for _, fn in ipairs(groups) do fn() end
  print(string.format("\n=== Results: %d/%d passed, %d failed ===", tests_passed, tests_run, #tests_failed))
  if #tests_failed > 0 then for _, f in ipairs(tests_failed) do print("  " .. f) end; os.exit(1) end
end
run_all()
