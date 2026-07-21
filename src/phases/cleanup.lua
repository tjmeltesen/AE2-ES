--[[
cleanup.lua -- Phase 6: CLEANUP (extracted from exec_broker.lua)

Releases the machine, updates job stats, and removes the entry from
activeJobs.  Draining and interface clearing are handled at the
TRANSFERRING → PROCESSING transition — cleanup only releases.

Obtains the TimeSliceScheduler via scheduler_registry (singleton).
No caller dependency, no nil-guard needed.
]]--

local schedulerRegistry = require("src.scheduler_registry")

local CleanupPhase = {}
CleanupPhase.__index = CleanupPhase

function CleanupPhase.new(context)
  assert(type(context.hal) == "table",
    "CleanupPhase requires hal (HAL)")
  assert(type(context.machines) == "table",
    "CleanupPhase requires machines table")
  assert(type(context.machineTransposers) == "table",
    "CleanupPhase requires machineTransposers table")
  assert(type(context.reports) == "table",
    "CleanupPhase requires reports table")
  assert(type(context.stats) == "table",
    "CleanupPhase requires stats table")

  return setmetatable({
    _hal                = context.hal,
    _machines           = context.machines,
    _machineTransposers = context.machineTransposers,
    _reports            = context.reports,
    _stats              = context.stats,
    _activeJobs         = context.activeJobs or {},
    _databaseAddr       = context.databaseAddr or "",
    _logger             = context.logger,
  }, CleanupPhase)
end

--- Execute one tick of the cleanup phase.
-- Fast-returns when no jobs have been flagged for cleanup since last run.
function CleanupPhase:execute(phases)
  if not self._activeJobs._dirtyCleanup then
    return
  end
  self._activeJobs._dirtyCleanup = nil

  local cleaned = {}
  local sched = schedulerRegistry.get()

  sched:forEachPair(self._activeJobs, function(laneId, active)
    if type(active) ~= "table" then return end
    if active.phase == phases.CLEANUP then
      self:_cleanupOne(laneId, active)
      table.insert(cleaned, laneId)
    end
  end)

  for _, laneId in ipairs(cleaned) do
    self._activeJobs[laneId] = nil
  end
end

function CleanupPhase:_cleanupOne(laneId, active)
  local machine  = self._machines[laneId]
  local manifest = active.manifest

  if machine then
    local released = machine:releaseJob()
    if not released then
      if machine:hasFault() then
        machine:clearFault()
      end
    end
  end

  manifest:unbindHardware()

  if manifest.status == "CLEANUP" then
    manifest:updateState("COMPLETED")
    self._stats.jobsCompleted = self._stats.jobsCompleted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + math.floor(manifest:age())
    manifest._inputRegistry = nil
    manifest._hardwareBinds = nil
    manifest._transferPlan = nil
    manifest._processingLog = nil
    manifest._errorLog = nil
  elseif manifest.status == "FAULTED" then
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + math.floor(manifest:age())
  end

  local report = self._reports[laneId]
  if report and not manifest.faultReason then
    report:clearFault("Job " .. manifest.id .. " completed successfully")
  end

  active.manifest = nil
end

return CleanupPhase
