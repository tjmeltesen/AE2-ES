--[[
processing.lua -- Phase 5: PROCESSING (extracted from exec_broker.lua)

Monitors active jobs' machines until they complete or fault.
Uses the machine's progress bar to schedule a wake-up time, eliminating
per-tick hardware polling for long-running recipes. Fast recipes
(< 1 tick) that complete before the first check are detected via the
idle flag and transitioned directly to cleanup.

Dependencies: receives HAL, machines, machineTransposers, reports,
stats, activeJobs, a clock function, and optionally a time-slice
scheduler and logger.
]]--

local schedulerRegistry = require("src.scheduler_registry")

local ProcessingPhase = {}
ProcessingPhase.__index = ProcessingPhase

-- Minimum interval (seconds) between polls when no progress bar is available.
local FALLBACK_POLL_INTERVAL = 2.0

-- Progress bar multiplier: start polling at 95% of estimated completion.
local WAKE_MULTIPLIER = 0.95

-- Max age (seconds) for fast-recipe detection after dispatch.
local FAST_RECIPE_MAX_AGE = 2.0

function ProcessingPhase.new(context)
  assert(type(context.hal) == "table",
    "ProcessingPhase requires hal (HAL)")
  assert(type(context.machines) == "table",
    "ProcessingPhase requires machines table")
  assert(type(context.machineTransposers) == "table",
    "ProcessingPhase requires machineTransposers table")
  assert(type(context.reports) == "table",
    "ProcessingPhase requires reports table")
  assert(type(context.stats) == "table",
    "ProcessingPhase requires stats table")

  -- Clock: defaults to os.time() (second resolution) for vanilla Lua.
  -- OC runtime injects computer.uptime() for sub-second precision.
  local clock = context.clock or os.time

  return setmetatable({
    _hal                = context.hal,
    _machines           = context.machines,
    _machineTransposers = context.machineTransposers,
    _reports            = context.reports,
    _stats              = context.stats,
    _activeJobs         = context.activeJobs or {},
    _logger             = context.logger,
    _clock              = clock,
  }, ProcessingPhase)
end

--- Execute one tick of processing for all active jobs.
-- @param phases table of phase name constants
function ProcessingPhase:execute(phases)
  local sched = schedulerRegistry.get()
  sched:forEachPair(self._activeJobs, function(laneId, active)
    if type(active) ~= "table" then return end
    if active.phase == phases.PROCESSING then
      local result = self:_checkOne(laneId, active, phases)
      if result ~= "still_processing" then self._activeJobs._dirtyCleanup = true end
    end
  end)
end

--- Extract progress and max progress from a poll result or sensor lines.
-- Prefers the GT API values (ticks) from the hardware poll, falling back
-- to sensor-line parsing.
-- @param hwState  table  result from HAL:pollMachineHardware
-- @param machine  MachineNode
-- @return number|nil progress, number|nil maxProgress
local function readProgressBar(hwState, machine)
  if hwState.maxProgress and hwState.maxProgress > 0 then
    return hwState.progress, hwState.maxProgress
  end

  -- Fallback: parse sensor lines (some machine types only expose it here)
  local lines = hwState.sensorLines
  if lines then
    for _, line in ipairs(lines) do
      if type(line) == "string" then
        -- Strip color codes, then extract
        local clean = line:gsub("[^%s%a%d%p][%a%d]?", "")
        local prog, maxProg = clean:match("Progress: ([^%s]*) s ?/ ?([^%s]*) ?s")
        if prog and maxProg then
          return tonumber(prog), tonumber(maxProg)
        end
      end
    end
  end

  -- Try cached progress (set by updateHardwareState)
  if machine._cachedProgress and machine._cachedProgress > 0 then
    return machine._cachedProgress, nil
  end

  return nil, nil
end

--- Check the progress of a single processing job.
function ProcessingPhase:_checkOne(laneId, active, phases)
  local machine = self._machines[laneId]
  if not machine then
    if self._logger then
      self._logger:error("PROCESSING: lane " .. laneId ..
        " machine node missing — faulting job " .. active.manifest.id)
    end
    active.manifest:fault("Machine node missing for " .. laneId)
    active.phase = phases.CLEANUP
    return "fault"
  end

  local manifest = active.manifest
  local now = self._clock()
  local firstCheck = active._procTicks == nil

  -- ====================================================================
  -- Wake-time guard: skip hardware poll while the machine is still running
  -- ====================================================================
  if not firstCheck then
    if active._wakeTime and active._wakeTime > 0 and now < active._wakeTime then
      -- Machine is running under a progress-bar timer — only check for faults
      if machine:hasFault() then
        local flags = machine.maintenanceFlags
        if self._logger then
          self._logger:warn("PROCESSING: lane " .. laneId ..
            " machine fault during sleep window: " .. (flags.description or "unknown"))
        end
        self._reports[laneId]:reportFault(flags.code, flags.description)
        manifest:fault("Machine fault: " .. (flags.description or "unknown"))
        self._stats.jobsFaulted = self._stats.jobsFaulted + 1
        active.phase = phases.CLEANUP
        return "fault"
      end
      return "still_processing"
    end

    -- Fallback interval guard: throttle when no progress bar available
    if active._wakeTime and active._wakeTime < 0 then
      if active._lastPoll and now < active._lastPoll + FALLBACK_POLL_INTERVAL then
        return "still_processing"
      end
    end
  end

  -- ====================================================================
  -- Hardware poll (runs on first check AND on every scheduled wake-up)
  -- ====================================================================
  local hwState = self._hal:pollMachineHardware(machine)
  active._lastPoll = now

  -- ====================================================================
  -- Fault detection (unchanged from original)
  -- ====================================================================
  if machine:hasFault() then
    local flags = machine.maintenanceFlags
    if self._logger then
      self._logger:warn("PROCESSING: lane " .. laneId ..
        " machine fault: " .. (flags.description or "unknown"))
    end
    self._reports[laneId]:reportFault(flags.code, flags.description)
    manifest:fault("Machine fault: " .. (flags.description or "unknown"))
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = phases.CLEANUP
    return "fault"
  end

  -- ====================================================================
  -- Maintenance health check
  -- ====================================================================
  local laneCfg = self._machineTransposers[laneId]
  if laneCfg then
    local health = self._hal:checkMaintenanceState(
      machine, laneCfg.transposerAddr, laneCfg.pull)
    local report = self._reports[laneId]
    if health and report then
      for _, advisory in ipairs(health.advisories or {}) do
        report:reportAdvisory(advisory.code, advisory.description)
      end
    end
    if health and health.faulted then
      if self._logger then
        self._logger:warn("PROCESSING: lane " .. laneId ..
          " health check found " .. tostring(#health.faults) .. " faults")
      end
      local hasBlockingFault = false
      for _, fault in ipairs(health.faults) do
        if fault.advisory then
          if report then report:reportAdvisory(fault.code, fault.description) end
        else
          hasBlockingFault = true
          if report then report:reportFault(fault.code, fault.description) end
        end
      end
      if hasBlockingFault then
        manifest:fault("Health check failed")
        self._stats.jobsFaulted = self._stats.jobsFaulted + 1
        active.phase = phases.CLEANUP
        return "fault"
      end
    end
  end

  -- ====================================================================
  -- Set progress-bar wake time on first check
  -- ====================================================================
  if firstCheck then
    -- Drain leftover items from the input bus.  GT machines consume all
    -- recipe inputs at once when the recipe starts — whatever remains
    -- in the bus by now is excess and won't be needed.
    local laneCfg = self._machineTransposers[laneId]
    if laneCfg and laneCfg.transposerAddr and laneCfg.push and laneCfg.return_ then
      self._hal:drainInventory(laneCfg.transposerAddr, laneCfg.push, laneCfg.return_)
    end

    local progress, maxProgress = readProgressBar(hwState, machine)

    if maxProgress and maxProgress > 0 then
      -- Compute wake time: 95% of estimated remaining duration
      local remainingTicks = maxProgress - (progress or 0)
      local remainingSec  = remainingTicks / 20  -- ticks → seconds
      active._wakeTime    = now + remainingSec * WAKE_MULTIPLIER
      active._maxProgress = maxProgress
      active._progressAt  = progress or 0

      if self._logger then
        self._logger:info(string.format(
          "PROCESSING: lane %s wake in %.1fs (progress=%d/%d ticks)",
          laneId, active._wakeTime - now, progress or 0, maxProgress))
      end
    elseif progress and progress > 0 then
      -- Progress bar found but no max — schedule a re-check
      active._wakeTime = now + 2  -- conservative: re-check in 2s
    else
      -- No progress bar — fall back to interval-based polling
      active._wakeTime = -1
    end

    active._procTicks = 0  -- will be incremented below
  end

  active._procTicks = active._procTicks + 1

  -- ====================================================================
  -- Fast recipe detection (idle on first check → recipe already finished)
  -- ====================================================================
  if firstCheck and hwState.active == false and not machine:hasFault() then
    local health = machine:parseHealth(hwState.sensorLines or {})
    if health.idle and manifest:age() < FAST_RECIPE_MAX_AGE then
      if self._logger then
        self._logger:info("PROCESSING: lane " .. laneId ..
          " fast recipe detected — idle on first check, → CLEANUP")
      end
      manifest:updateState("CLEANUP")
      active.phase = phases.CLEANUP
      return "cleanup"
    end
  end

  -- ====================================================================
  -- Completion detection
  -- ====================================================================
  local isActive = hwState.active or false

  if not isActive and (active._procTicks >= 2 or math.floor(manifest:age()) > 2) then
    -- Before treating as completion, verify the machine isn't broken.
    -- A machine that went inactive due to power loss, maintenance, or
    -- structural issues should fault the job — not release the lane
    -- into the allocation pool.
    local health = machine:parseHealth(hwState.sensorLines or {})
    if not health.ok then
      local reason = #health.issues > 0 and table.concat(health.issues, ",") or "unhealthy"
      if self._logger then
        self._logger:warn("PROCESSING: lane " .. laneId ..
          " machine unhealthy at completion (" .. reason .. ") — faulting job")
      end
      manifest:fault("Machine unhealthy at completion: " .. reason)
      self._stats.jobsFaulted = self._stats.jobsFaulted + 1
      active.phase = phases.CLEANUP
      return "fault"
    end

    if self._logger then
      self._logger:info("PROCESSING: lane " .. laneId ..
        " job " .. manifest.id .. " complete → CLEANUP")
    end
    manifest:updateState("CLEANUP")
    active.phase = phases.CLEANUP
    return "cleanup"
  end

  -- Staleness is a safety net only for machines we can't track via
  -- progress bar.  When _wakeTime is tracking the recipe duration,
  -- the job is expected to live that long — don't fault it.
  if not (active._wakeTime and active._wakeTime > 0) and manifest:isStale() then
    if self._logger then
      self._logger:warn("PROCESSING: lane " .. laneId ..
        " job " .. manifest.id .. " timed out (stale)")
    end
    manifest:fault("Processing timed out (stale)")
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = phases.CLEANUP
    return "fault"
  end

  return "still_processing"
end

return ProcessingPhase
