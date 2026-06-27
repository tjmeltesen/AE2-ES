-- JobQueue.lua
-- AE2-ES Module A4: JobQueue
-- Internal container managing priority and sequence of JobManifests.
-- Handles out-of-order concurrent dispatch with stale detection.

local JobQueue = {}
JobQueue.__index = JobQueue

-- Constants
local DEFAULT_MAX_SIZE      = 64
local DEFAULT_STALE_TIMEOUT = 300

--- Create a new JobQueue instance.
-- @param maxSize  number  maximum number of jobs (default 64)
-- @return JobQueue instance
function JobQueue.new(maxSize)
  return setmetatable({
    _queue        = {},
    _maxSize      = maxSize or DEFAULT_MAX_SIZE,
    _staleTimeout = DEFAULT_STALE_TIMEOUT,
    _dispatchIdx  = 1,
  }, JobQueue)
end

--- Push a job/manifest into the queue, maintaining priority order (descending).
-- Higher priority values sort first; equal priority jobs maintain FIFO order.
-- @param manifest  table  job with at minimum an .id field
-- @return boolean  true if accepted, false if full or invalid
function JobQueue:push(manifest)
  if #self._queue >= self._maxSize then
    return false
  end
  if type(manifest) ~= "table" or not manifest.id then
    return false
  end

  manifest.priority  = manifest.priority  or 0
  manifest.createdAt = manifest.createdAt or os.time()
  manifest.updatedAt = manifest.updatedAt or os.time()
  manifest.status    = manifest.status    or "PENDING"

  local inserted = false
  for i, j in ipairs(self._queue) do
    if (j.priority or 0) < (manifest.priority or 0) then
      table.insert(self._queue, i, manifest)
      inserted = true
      break
    end
  end
  if not inserted then
    table.insert(self._queue, manifest)
  end
  return true
end

--- Pop the highest-priority available (PENDING, non-stale) job.
-- Ties broken by earliest createdAt (FIFO within equal priority).
-- Sets popped job status to "DISPATCHED".
-- @return table|nil  the job, or nil if none available
function JobQueue:popNextAvailable()
  if #self._queue == 0 then return nil end

  local bestIdx = nil
  local bestPri = -math.huge
  local bestAge = math.huge

  for i, job in ipairs(self._queue) do
    local status = job.status or "PENDING"
    if status ~= "PENDING" then goto continue end
    if self:_isStale(job) then goto continue end

    local pri = job.priority or 0
    local age = job.createdAt or 0

    if pri > bestPri then
      bestIdx = i
      bestPri = pri
      bestAge = age
    elseif pri == bestPri and age < bestAge then
      bestIdx = i
      bestAge = age
    end
    ::continue::
  end

  if bestIdx then
    local job = table.remove(self._queue, bestIdx)
    job.status    = "DISPATCHED"
    job.updatedAt = os.time()
    self._dispatchIdx = bestIdx
    return job
  end
  return nil
end

--- Remove all stale jobs from the queue and return the count removed.
-- Stale = PENDING with updatedAt older than _staleTimeout.
-- Terminal states (COMPLETED, FAULTED) are never removed.
-- @param now  number  reference time (default os.time())
-- @return number  count of jobs removed
function JobQueue:validateQueue(now)
  now = now or os.time()
  local removed = 0
  local i = 1
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

--- Check if a job is stale (internal).
-- Jobs with a custom :isStale() method delegate to it.
-- @param job   table
-- @param now   number
-- @return boolean
function JobQueue:_isStale(job, now)
  now = now or os.time()
  if job.status == "COMPLETED" or job.status == "FAULTED" then
    return false
  end
  if type(job.isStale) == "function" then
    return job:isStale(now)
  end
  local lastUpdate = job.updatedAt or job.createdAt or now
  return (now - lastUpdate) > self._staleTimeout
end

--- Get a snapshot of every job in the queue (immutable copies).
-- @return table  array of {id, status, priority, createdAt, updatedAt}
function JobQueue:peek()
  local snap = {}
  for _, job in ipairs(self._queue) do
    snap[#snap + 1] = {
      id        = job.id,
      status    = job.status,
      priority  = job.priority,
      createdAt = job.createdAt,
      updatedAt = job.updatedAt,
    }
  end
  return snap
end

--- Get the number of jobs currently in the queue.
-- @return number
function JobQueue:length()
  return #self._queue
end

--- Check if the queue is at capacity.
-- @return boolean
function JobQueue:isFull()
  return #self._queue >= self._maxSize
end

--- Get the maximum queue size.
-- @return number
function JobQueue:getMaxSize()
  return self._maxSize
end

--- Get the current stale timeout (seconds).
-- @return number
function JobQueue:getStaleTimeout()
  return self._staleTimeout
end

--- Set the stale timeout.
-- @param seconds  number  must be >= 1
function JobQueue:setStaleTimeout(seconds)
  assert(type(seconds) == "number" and seconds >= 1, "staleTimeout must be a positive number")
  self._staleTimeout = seconds
end

--- Cancel (remove) a job by its id.
-- @param jobId  string
-- @return boolean  true if found and removed
function JobQueue:cancel(jobId)
  for i, job in ipairs(self._queue) do
    if job.id == jobId then
      table.remove(self._queue, i)
      return true
    end
  end
  return false
end

--- Update the status of a job in-place.
-- @param jobId      string
-- @param newStatus  string
-- @return boolean   true if found
function JobQueue:updateStatus(jobId, newStatus)
  for _, job in ipairs(self._queue) do
    if job.id == jobId then
      job.status    = newStatus
      job.updatedAt = os.time()
      return true
    end
  end
  return false
end

--- Empty the queue completely.
function JobQueue:clear()
  self._queue      = {}
  self._dispatchIdx = 1
end

--- Get an iterator over all jobs (in priority order).
-- @return function  iterator (one job per call, nil when exhausted)
function JobQueue:iter()
  local i = 0
  return function()
    i = i + 1
    return self._queue[i]
  end
end

return JobQueue
