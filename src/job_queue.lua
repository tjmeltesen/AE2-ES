-- Canonical JobQueue domain module. Safe to import outside OpenComputers.

local JobQueue = {}
JobQueue.__index = JobQueue

local DEFAULT_MAX_SIZE = 64
local DEFAULT_STALE_TIMEOUT = 300

function JobQueue.new(maxSize)
  return setmetatable({
    _queue = {},
    _maxSize = maxSize or DEFAULT_MAX_SIZE,
    _staleTimeout = DEFAULT_STALE_TIMEOUT,
    _dispatchIdx = 1,
  }, JobQueue)
end

-- Reject new work when the queue is full. This is deliberately not a
-- trimming queue: callers must handle backpressure themselves.
function JobQueue:push(manifest)
  if #self._queue >= self._maxSize then return false end
  if type(manifest) ~= "table" or not manifest.id then return false end

  manifest.priority = manifest.priority or 0
  manifest.createdAt = manifest.createdAt or os.time()
  manifest.updatedAt = manifest.updatedAt or os.time()
  manifest.status = manifest.status or "PENDING"

  for i, job in ipairs(self._queue) do
    if (job.priority or 0) < manifest.priority then
      table.insert(self._queue, i, manifest)
      return true
    end
  end
  table.insert(self._queue, manifest)
  return true
end

function JobQueue:popNextAvailable()
  if #self._queue == 0 then return nil end

  local bestIdx, bestPriority, bestAge = nil, -math.huge, math.huge
  for i, job in ipairs(self._queue) do
    local status = job.status or "PENDING"
    if status == "PENDING" and not self:_isStale(job) then
      local priority, age = job.priority or 0, job.createdAt or 0
      if priority > bestPriority or (priority == bestPriority and age < bestAge) then
        bestIdx, bestPriority, bestAge = i, priority, age
      end
    end
  end

  if not bestIdx then return nil end
  local job = table.remove(self._queue, bestIdx)
  job.status = "DISPATCHED"
  job.updatedAt = os.time()
  self._dispatchIdx = bestIdx
  return job
end

function JobQueue:validateQueue(now)
  now = now or os.time()
  local removed, i = 0, 1
  while i <= #self._queue do
    if self:_isStale(self._queue[i], now) then
      table.remove(self._queue, i)
      removed = removed + 1
    else
      i = i + 1
    end
  end
  return removed
end

function JobQueue:_isStale(job, now)
  now = now or os.time()
  if job.status == "COMPLETED" or job.status == "FAULTED" then return false end
  if type(job.isStale) == "function" then return job:isStale(now) end
  return (now - (job.updatedAt or job.createdAt or now)) > self._staleTimeout
end

function JobQueue:peek()
  local snapshot = {}
  for _, job in ipairs(self._queue) do
    snapshot[#snapshot + 1] = {
      id = job.id, status = job.status, priority = job.priority,
      createdAt = job.createdAt, updatedAt = job.updatedAt,
    }
  end
  return snapshot
end

--- Return the complete queue for persistence. Callers must treat the returned
-- manifests as data only and never mutate the live queue through it.
function JobQueue:toPersistence()
  local jobs = {}
  for index, job in ipairs(self._queue) do
    jobs[index] = job
  end
  return jobs
end

--- Restore persisted jobs through push so queue capacity and ordering rules
-- remain identical to normal intake.
function JobQueue:restorePersistence(jobs)
  if type(jobs) ~= "table" then return false, "jobs must be a table" end
  local restored = 0
  for _, job in ipairs(jobs) do
    if type(job) ~= "table" or type(job.id) ~= "string" then
      return false, "invalid persisted job"
    end
    if not self:push(job) then return false, "persisted queue is full" end
    restored = restored + 1
  end
  return true, restored
end

function JobQueue:length() return #self._queue end
function JobQueue:isFull() return #self._queue >= self._maxSize end
function JobQueue:getMaxSize() return self._maxSize end
function JobQueue:getStaleTimeout() return self._staleTimeout end

function JobQueue:setStaleTimeout(seconds)
  assert(type(seconds) == "number" and seconds >= 1, "staleTimeout must be a positive number")
  self._staleTimeout = seconds
end

function JobQueue:cancel(jobId)
  for i, job in ipairs(self._queue) do
    if job.id == jobId then
      table.remove(self._queue, i)
      return true
    end
  end
  return false
end

function JobQueue:updateStatus(jobId, newStatus)
  for _, job in ipairs(self._queue) do
    if job.id == jobId then
      job.status = newStatus
      job.updatedAt = os.time()
      return true
    end
  end
  return false
end

function JobQueue:clear()
  self._queue = {}
  self._dispatchIdx = 1
end

function JobQueue:iter()
  local i = 0
  return function()
    i = i + 1
    return self._queue[i]
  end
end

return JobQueue
