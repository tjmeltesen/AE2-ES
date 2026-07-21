--[[
allocating.lua -- Phase 3: ALLOCATING

Pops the next pending job, health-checks available machines via sensor
data, picks the healthiest, locks it, binds the job, → TRANSFERRING.

All loops are wrapped by TimeSliceScheduler to prevent TMI.
]]

local schedulerRegistry = require("src.scheduler_registry")

local AllocatingPhase = {}
AllocatingPhase.__index = AllocatingPhase

function AllocatingPhase.new(context)
  assert(type(context.queue) == "table", "AllocatingPhase requires queue")
  assert(type(context.machineList) == "table", "AllocatingPhase requires machineList")
  return setmetatable({
    _queue       = context.queue,
    _machineList = context.machineList,
    _activeJobs  = context.activeJobs or {},
    _logger      = context.logger,
    _hal         = context.hal,
  }, AllocatingPhase)
end

local function refreshHealth(self, node)
  if not self._hal then return end
  local health = self._hal:quickHealthCheck(node)
  node._healthScore  = health.healthScore
  node._healthIssues = health.issues or {}
end

function AllocatingPhase:execute(phases)
  local sched = schedulerRegistry.get()

  -- Don't start a transfer while Database is in use
  local transferring = false
  sched:forEachPair(self._activeJobs, function(_, a)
    if transferring then return end
    if type(a) ~= "table" then return end
    if a.phase == phases.TRANSFERRING then transferring = true end
  end)
  if transferring then return phases.ALLOCATING end

  local job = self._queue:popNextAvailable()
  if not job then return phases.BUFFERING end

  local candidates = {}
  local selfRef = self

  sched:forEach(self._machineList, function(entry)
    if not entry.node then
      if selfRef._logger then selfRef._logger:warn("ALLOCATING: lane " .. tostring(entry.laneId) .. " has no node") end
      return
    end
    if type(entry.node.isAvailable) ~= "function" then
      if selfRef._logger then selfRef._logger:warn("ALLOCATING: lane " .. tostring(entry.laneId) .. " node missing metatable") end
      return
    end
    if not entry.node:isAvailable() then return end
    if selfRef._activeJobs[entry.laneId] then return end

    refreshHealth(selfRef, entry.node)

    if entry.node:isHealthy() then
      table.insert(candidates, { entry = entry, healthScore = entry.node:getHealthScore() })
    elseif selfRef._logger then
      local issues = entry.node:getHealthIssues()
      selfRef._logger:warn("ALLOCATING: skipping " .. tostring(entry.laneId) ..
        " — unhealthy (score=" .. tostring(entry.node:getHealthScore()) ..
        ", " .. (#issues > 0 and table.concat(issues, ",") or "unknown") .. ")")
    end
  end)

  if #candidates > 1 then
    table.sort(candidates, function(a, b) return a.healthScore > b.healthScore end)
  end

  local target = #candidates > 0 and candidates[1].entry or nil
  if target and self._logger then
    self._logger:info("ALLOCATING: dispatching to " .. tostring(target.laneId) .. " (health=" .. tostring(candidates[1].healthScore) .. ")")
  end

  if not target then
    if self._logger then self._logger:warn("ALLOCATING: no healthy machines, re-queuing job " .. tostring(job.id)) end
    job.status = "PENDING"; self._queue:push(job)
    return phases.ALLOCATING
  end

  if type(target.node.lock) ~= "function" or not target.node:lock() then
    job.status = "PENDING"; self._queue:push(job)
    return phases.ALLOCATING
  end
  if type(target.node.bindJob) ~= "function" or not target.node:bindJob(job) then
    target.node:unlock(); job.status = "PENDING"; self._queue:push(job)
    return phases.ALLOCATING
  end

  job.status = "ALLOCATING"
  job.updatedAt = os.time()
  job:bindHardware(target.address)

  self._activeJobs[target.laneId] = { manifest = job, phase = phases.ALLOCATING, assignedAt = os.time() }
  return phases.TRANSFERRING
end

return AllocatingPhase
