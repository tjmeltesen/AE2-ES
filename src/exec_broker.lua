--[[
exec_broker.lua — AE2-ES Exec Broker Main Event Loop (A8)
Part of Deliverable A: Exec Broker

6-phase state machine orchestrating a localized machine array:
  BUFFERING → LOGGING → ALLOCATING → TRANSFERRING → PROCESSING → CLEANUP

Integrates all Exec Broker modules:
  JobManifest (A1), MachineNode (A2), BufferSnapshot (A3), JobQueue (A4),
  HardwareAbstractionLayer (A5), MaintenanceReport (A6), TelemetryPayload (A7)

Cooperative multitasking via event.pull() — all phases yield.
Fire-and-forget telemetry to Supervisor via modem broadcast.

Dependency injection: all modules and hardware references injectable
via config for testability without OC runtime.
]]--

local ExecBroker = {}
ExecBroker.__index = ExecBroker

-- ===========================================================================
-- Broker phases (6-phase state machine)
-- ===========================================================================
ExecBroker.PHASES = {
  BUFFERING    = "BUFFERING",
  LOGGING      = "LOGGING",
  ALLOCATING   = "ALLOCATING",
  TRANSFERRING = "TRANSFERRING",
  PROCESSING   = "PROCESSING",
  CLEANUP      = "CLEANUP",
}

-- ===========================================================================
-- Internal helpers
-- ===========================================================================

--- Safe module loader: tries pcall(require), returns nil on failure.
-- Used to load modules that may reference OC runtime libraries.
-- @param name  string  module name
-- @return module or nil
local function safeRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

--- Get current clock: prefer computer.uptime() for sub-second precision,
-- fall back to os.time() for whole-second precision.
-- @return number  seconds
local function now()
  if ExecBroker._clockOverride then
    return ExecBroker._clockOverride()
  end
  local ok, computer = pcall(require, "computer")
  if ok and type(computer.uptime) == "function" then
    return computer.uptime()
  end
  -- Use os.clock() for sub-second precision in test environments
  -- (os.clock returns CPU time, not wall time, but gives sub-second resolution)
  return os.time() + (os.clock() % 1)
end

-- ===========================================================================
-- Module registry
-- ===========================================================================

--- Default module loader — tries to load from package.loaded or require.
-- Callers can override any module via config.modules.
local DEFAULT_MODULES = {
  JobManifest        = function() return safeRequire("JobManifest") end,
  MachineNode        = function() return safeRequire("src.MachineNode") end,
  BufferSnapshot     = function() return safeRequire("src.BufferSnapshot") end,
  JobQueue           = function() return safeRequire("JobQueue") end,
  HAL                = function() return safeRequire("src.hal") end,
  MaintenanceReport  = function() return safeRequire("MaintenanceReport") end,
  TelemetryPayload   = function() return safeRequire("src.telemetrypayload") end,
}

-- ===========================================================================
-- Constructor
-- ===========================================================================

--- Create a new ExecBroker instance.
-- @param config  table with keys:
--   brokerId         — string, unique broker identifier (required)
--   machines         — array, [{laneId, machineAddr}] (required)
--   machineTransposers — table, {[laneId] = {dualInterface, transposerAddr, machineAddr, pull, push, return}}
--   itemBufferAddr   — string, drawer controller address (global item buffer)
--   fluidBufferAddr  — string, fluid hatch address (global fluid buffer)
--   databaseAddr     — string, OC database address (item stack data for transfer)
--   halConfig        — table, passed to HAL:new() (sideMap, cacheTTL, etc.)
--   queueSize        — number, max JobQueue size (default 64)
--   bufferFeeder     — function() -> bufferData, for reading item/fluid buffers
--   modem            — table, modem component for telemetry (optional)
--   telemetryPort    — number, modem port for broadcasts (default 123)
--   pollInterval     — number, seconds between buffer polls (default 0.5)
--   heartbeatInterval— number, seconds between telemetry broadcasts (default 2.0)
--   debounceWindow   — number, BufferSnapshot stability window (default 1.5)
-- @return ExecBroker instance
function ExecBroker.new(config)
  assert(config ~= nil, "ExecBroker requires a config table")
  assert(type(config.brokerId) == "string" and #config.brokerId > 0,
    "ExecBroker requires brokerId")
  assert(type(config.machines) == "table", "ExecBroker requires machines table")

  -- Load modules (config overrides default loaders)
  local M = {}
  for name, loader in pairs(DEFAULT_MODULES) do
    if config.modules and config.modules[name] ~= nil then
      M[name] = config.modules[name]
    else
      M[name] = loader()
    end
  end

  -- Validate required modules
  for _, name in ipairs({
    "JobManifest", "MachineNode", "BufferSnapshot", "JobQueue",
    "HAL", "MaintenanceReport", "TelemetryPayload"
  }) do
    assert(M[name] ~= nil,
      "ExecBroker: module '" .. name .. "' is required but could not be loaded")
  end

  -- Create HAL instance
  -- Build halConfig: accept nested form (from buildExecConfig) or flat form (from saved config)
  local halConfig = config.halConfig or {}
  if config.halSideMap and not halConfig.sideMap then
    halConfig.sideMap = config.halSideMap
  end
  local hal = M.HAL:new(halConfig)

  -- Create BufferSnapshot
  local snapshot = config.snapshot or M.BufferSnapshot.new(config.debounceWindow or 1.5)

  -- Create JobQueue
  local queue = config.queue or M.JobQueue.new(config.queueSize or 64)

  -- Maintenance reports: one per lane (keyed by laneId)
  local reports = {}
  local machineList = {}
  local machinesByLane = {}

  -- Backward compat: accept old {address -> MachineNode} dict or new [{laneId, ...}] array
  local machineEntries
  if config.machines[1] and type(config.machines[1]) == "table" then
    -- New lane array format: [{laneId, machineAddr, adapter}]
    machineEntries = config.machines
  else
    -- Old address->node dict: convert to lane array
    machineEntries = {}
    for addr, node in pairs(config.machines) do
      table.insert(machineEntries, {
        laneId = addr,
        machineAddr = addr,
        _node = node,
      })
    end
  end

  for _, lane in ipairs(machineEntries) do
    local laneId = lane.laneId
    local machineAddr = lane.machineAddr or lane.address

    -- Use pre-built node if provided (backward compat), otherwise create one
    local node = lane._node
    if not node then
      if M.MachineNode and type(M.MachineNode.new) == "function" then
        node = M.MachineNode.new(machineAddr, {
          machineType = "gt_machine",
          hardwareAddress = machineAddr,
          laneId = laneId,
        })
      else
        node = { address = machineAddr, laneId = laneId }
      end
    end

    machinesByLane[laneId] = node
    reports[laneId] = M.MaintenanceReport.new(laneId)
    table.insert(machineList, { laneId = laneId, address = machineAddr, node = node })
  end

  -- Sort for deterministic iteration
  table.sort(machineList, function(a, b) return a.laneId < b.laneId end)

  -- Logger for diagnostics and error tracking
  local BrokerLogger = config.logger or safeRequire("src.broker_logger")
  local logger = nil
  if BrokerLogger and type(BrokerLogger.new) == "function" then
    logger = BrokerLogger.new(config.brokerId)
  end

  local self = setmetatable({
    -- Identity
    _brokerId        = config.brokerId,
    _phase           = ExecBroker.PHASES.BUFFERING,

    -- Modules
    _M               = M,
    _hal             = hal,
    _snapshot        = snapshot,
    _queue           = queue,
    _reports         = reports,
    _logger          = logger,

    -- Hardware
    _machines        = machinesByLane,
    _machineList     = machineList,
    _machineTransposers = config.machineTransposers or {},
    _itemBufferAddr  = config.itemBufferAddr or "",
    _fluidBufferAddr = config.fluidBufferAddr or "",
    _databaseAddr    = config.databaseAddr or "",

    -- I/O
    _bufferFeeder    = config.bufferFeeder,
    _modem           = config.modem,
    _telemetryPort   = config.telemetryPort or 123,

    -- Timing
    _pollInterval     = config.pollInterval or 0.5,
    _heartbeatInterval = config.heartbeatInterval or 2.0,
    _lastPollTime     = 0,
    _lastHeartbeat    = 0,
    _tickCount        = 0,
    _running          = true,

    -- Active jobs: { [laneId] = { manifest, phase, assignedAt } }
    _activeJobs       = {},

    -- Statistics
    _stats            = {
      jobsCompleted   = 0,
      jobsFaulted     = 0,
      totalJobTime    = 0,
      cycles          = 0,
    },

    -- Event handlers (injectable for testing)
    _eventPull        = config.eventPull,     -- function(timeout) -> signal, ...
    _eventPullFiltered= config.eventPullFiltered,
  }, ExecBroker)

  -- Auto-create bufferFeeder from addresses if not provided
  -- (config loaded from disk has addresses but no feeder function)
  if self._bufferFeeder == nil and (self._itemBufferAddr ~= "" or self._fluidBufferAddr ~= "") then
    local ibAddr = self._itemBufferAddr
    local fbAddr = self._fluidBufferAddr
    local component = safeRequire("component")
    local itemSide = self._hal:resolveSide("itemBuffer") or 0
    local fluidSide = self._hal:resolveSide("fluidBuffer") or 1
    self._bufferFeeder = function()
      local items, fluids = {}, {}
      -- Item buffer: inventory_controller uses getInventorySize + getStackInSlot
      if component and ibAddr ~= "" then
        local ok, proxy = pcall(component.proxy, ibAddr)
        if ok and proxy then
          local szOk, sz = pcall(proxy.getInventorySize, proxy, itemSide)
          if szOk and type(sz) == "number" and sz > 0 then
            for slot = 1, math.min(sz, 128) do
              local stOk, stack = pcall(proxy.getStackInSlot, proxy, itemSide, slot)
              if stOk and stack and stack.size and stack.size > 0 then
                table.insert(items, {
                  name = stack.name or stack.label or "unknown",
                  label = stack.label or stack.name or "unknown",
                  size = stack.size,
                })
              end
            end
          end
        end
      end
      -- Fluid buffer: tank_controller uses getTankCount + getFluidInTank
      if component and fbAddr ~= "" then
        local ok, proxy = pcall(component.proxy, fbAddr)
        if ok and proxy then
          local tcOk, tankCount = pcall(proxy.getTankCount, proxy, fluidSide)
          if tcOk and type(tankCount) == "number" and tankCount > 0 then
            for tank = 1, math.min(tankCount, 32) do
              local flOk, fluid = pcall(proxy.getFluidInTank, proxy, fluidSide, tank)
              if flOk and fluid and fluid.label then
                local lvOk, level = pcall(proxy.getTankLevel, proxy, fluidSide, tank)
                table.insert(fluids, {
                  name = fluid.name or fluid.label or "unknown",
                  label = fluid.label or "unknown",
                  amount = (lvOk and level) or 0,
                })
              end
            end
          end
        end
      end
      return { items = items, fluids = fluids }
    end
  end

  return self
end

-- ===========================================================================
-- Phase 1: BUFFERING — Monitor central buffer for stability
-- ===========================================================================

--- Execute the BUFFERING phase.
-- Polls buffer via bufferFeeder, updates BufferSnapshot.
-- If stable, converts to JobManifest and transitions to LOGGING.
-- @return string  next phase (LOGGING or BUFFERING)
function ExecBroker:_phaseBUFFERING()
  if not self._bufferFeeder then
    if self._logger then self._logger:warn("BUFFERING: no bufferFeeder configured") end
    return ExecBroker.PHASES.BUFFERING
  end
  -- Poll the central buffer
  local bufferData = self._bufferFeeder()
  if type(bufferData) ~= "table" then
    if self._logger then self._logger:warn("BUFFERING: bufferFeeder returned non-table: " .. type(bufferData)) end
    return ExecBroker.PHASES.BUFFERING
  end

  -- Update snapshot with new data
  local stable = self._snapshot:update(bufferData)
  if self._logger then self._logger:info("BUFFERING: snapshot stable=" .. tostring(stable)) end

  if not stable then
    -- Still waiting for stability; yield and try again
    if self._logger then self._logger:info("BUFFERING: snapshot not stable, waiting") end
    return ExecBroker.PHASES.BUFFERING
  end

  -- Check if there's actually data in the stable snapshot
  local snapData = self._snapshot:getSnapshotData()
  if not snapData then
    if self._logger then self._logger:warn("BUFFERING: snapshot has no data") end
    return ExecBroker.PHASES.BUFFERING
  end

  local hasItems = (snapData.items and #snapData.items > 0)
  local hasFluids = (snapData.fluids and #snapData.fluids > 0)
  if self._logger then self._logger:info("BUFFERING: hasItems=" .. tostring(hasItems) .. ", hasFluids=" .. tostring(hasFluids)) end
  if not hasItems and not hasFluids then
    -- Stable but empty — nothing to process; reset and wait
    if self._logger then self._logger:info("BUFFERING: snapshot is empty, resetting") end
    self._snapshot:reset()
    return ExecBroker.PHASES.BUFFERING
  end

  -- Stable with data — transition to LOGGING
  if self._logger then self._logger:info("BUFFERING: snapshot is stable with data, transitioning to LOGGING") end
  return ExecBroker.PHASES.LOGGING
end

-- ===========================================================================
-- Phase 2: LOGGING — Convert snapshot to JobManifest and queue
-- ===========================================================================

--- Execute the LOGGING phase.
-- Converts the stable snapshot into a JobManifest and pushes to queue.
-- @return string  next phase (ALLOCATING or BUFFERING)
function ExecBroker:_phaseLOGGING()
  -- Convert stable snapshot to manifest
  local manifest = self._snapshot:convertToManifest(0)

  if not manifest then
    -- Snapshot became unstable or lost data; go back
    return ExecBroker.PHASES.BUFFERING
  end

  -- Log the job creation
  local job = self._M.JobManifest.new(manifest.id, manifest.inputs)
  job.priority = manifest.priority or 0
  job.status   = "PENDING"
  job.createdAt = manifest.createdAt or os.time()
  job.updatedAt = manifest.updatedAt or os.time()

  -- Push to queue
  local pushed = self._queue:push(job)
  if not pushed then
    -- Queue full — log a warning and retry later
    return ExecBroker.PHASES.LOGGING
  end

  -- Reset snapshot for next buffering cycle
  self._snapshot:reset()

  -- Move to allocator phase
  return ExecBroker.PHASES.ALLOCATING
end

-- ===========================================================================
-- Phase 3: ALLOCATING — Find available machine, lock & bind
-- ===========================================================================

--- Execute the ALLOCATING phase.
-- Pops next available job from queue, finds an available machine,
-- locks it, and binds the job.
-- @return string  next phase (TRANSFERRING, ALLOCATING, or BUFFERING)
function ExecBroker:_phaseALLOCATING()
  -- Pop next available job from queue
  local job = self._queue:popNextAvailable()
  if not job then
    -- No jobs pending — go back to buffering
    return ExecBroker.PHASES.BUFFERING
  end

  -- Find an available machine
  local target = nil
  for _, entry in ipairs(self._machineList) do
    if entry.node:isAvailable() then
      target = entry
      break
    end
  end

  if not target then
    -- No machines available — push job back (re-queue)
    job.status = "PENDING"
    self._queue:push(job)
    -- Stay in ALLOCATING to retry next tick
    return ExecBroker.PHASES.ALLOCATING
  end

  -- Lock the machine
  local locked = target.node:lock()
  if not locked then
    -- Race condition — machine became unavailable
    job.status = "PENDING"
    self._queue:push(job)
    return ExecBroker.PHASES.ALLOCATING
  end

  -- Bind job to machine (LOCKED → PROCESSING)
  local bound = target.node:bindJob(job)
  if not bound then
    target.node:unlock()
    job.status = "PENDING"
    self._queue:push(job)
    return ExecBroker.PHASES.ALLOCATING
  end

  -- Update manifest state directly (skip JobManifest transition validation
  -- since the queue's DISPATCHED status is not a valid manifest state)
  job.status = "ALLOCATING"
  job.updatedAt = os.time()
  job:bindHardware(target.address)

  -- Track active job and perform transfer immediately (single-tick allocation)
  self._activeJobs[target.address] = {
    manifest    = job,
    phase       = ExecBroker.PHASES.ALLOCATING,
    assignedAt  = os.time(),
  }

  -- Perform transfer immediately (single-tick: ALLOCATING → PROCESSING)
  self:_transferForJob(target.address, self._activeJobs[target.address])

  -- Check if transfer succeeded or faulted
  if self._activeJobs[target.address].phase == ExecBroker.PHASES.CLEANUP then
    -- Transfer faulted — go to cleanup
    return ExecBroker.PHASES.CLEANUP
  end

  return ExecBroker.PHASES.PROCESSING
end

-- ===========================================================================
-- Phase 4: TRANSFERRING — Move items from buffer to machine interface
-- ===========================================================================

--- Execute the TRANSFERRING phase for all active jobs.
-- Uses HAL to transfer items from the central buffer to each allocated
-- machine's ME interface. Transitions to PROCESSING once all transfers complete.
-- @return string  next phase (PROCESSING or TRANSFERRING)
function ExecBroker:_phaseTRANSFERRING()
  -- Phase 1: Process jobs already in TRANSFERRING
  for addr, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.TRANSFERRING then
      self:_transferForJob(addr, active)
    end
  end

  -- Phase 2: Promote ALLOCATING jobs and transfer
  for addr, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.ALLOCATING then
      active.phase = ExecBroker.PHASES.TRANSFERRING
      self:_transferForJob(addr, active)
    end
  end

  -- After all transfers, check if any jobs are still in TRANSFERRING or ALLOCATING
  for _, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.TRANSFERRING or
       active.phase == ExecBroker.PHASES.ALLOCATING then
      return ExecBroker.PHASES.TRANSFERRING
    end
  end

  -- All jobs advanced to PROCESSING (or CLEANUP on error)
  return ExecBroker.PHASES.PROCESSING
end

--- Transfer items for a specific job from central buffer to machine interface.
-- @param addr    string  machine address
-- @param active  table   active job entry
function ExecBroker:_transferForJob(addr, active)
  local manifest = active.manifest

  -- Transition manifest to TRANSFERRING
  if manifest.status == "ALLOCATING" then
    manifest:updateState("TRANSFERRING")
  end

  -- Resolve sides: output from central buffer, input to machine interface
  local fromSide = self._hal:resolveSide("itemBuffer")
  local toSide   = self._hal:resolveSide("interface")

  if not fromSide or not toSide then
    -- Cannot resolve sides — fault the job
    manifest:fault("Cannot resolve transfer sides")
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  -- Drain items from central buffer to machine interface
  local transferred = self._hal:drainInventory(fromSide, toSide)
  if transferred == nil then
    -- HAL error — check if this is a recoverable error
    local halErr = self._hal:getLastError()
    if halErr then
      -- Fault the job with HAL error context
      manifest:fault("Transfer failed: " .. halErr)
      active.phase = ExecBroker.PHASES.CLEANUP
      return
    end
  end

  -- Transfer fluids if the machine has fluid capabilities
  local machine = self._machines[addr]
  if machine then
    local hasFluidCap = self._hal:hasCapability(
      machine:getMachineType(),
      self._hal.CAP_FLUID_INPUT
    )

    if hasFluidCap then
      local fromHatchSide = self._hal:resolveSide("inputHatch")
      -- Fluid enters machine via input hatch (auto-delivered by ender fluid conduit)
      -- Output returns to separate network — no outputHatch needed here
      local toHatchSide   = self._hal:resolveSide("fluidBuffer")
      if fromHatchSide then
        self._hal:performFluidTransfer(fromHatchSide, toHatchSide or fromHatchSide)
      end
    end
  end

  -- Transfer complete — move to PROCESSING
  manifest:updateState("PROCESSING")
  active.phase = ExecBroker.PHASES.PROCESSING
end

-- ===========================================================================
-- Phase 5: PROCESSING — Monitor machine until job completes
-- ===========================================================================

--- Execute the PROCESSING phase for all active jobs.
-- Polls hardware, detects completion and faults.
-- @return string  next phase (CLEANUP, PROCESSING, or ALLOCATING)
function ExecBroker:_phasePROCESSING()
  local allDone = true

  for addr, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.PROCESSING then
      local result = self:_checkProcessingJob(addr, active)
      if result == "still_processing" then
        allDone = false
      end
      -- If "cleanup", phase was changed to CLEANUP
      -- If "fault", phase was changed to CLEANUP
    end
  end

  -- If no active processing jobs, try ALLOCATING more work
  local hasProcessing = false
  for _, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.PROCESSING then
      hasProcessing = true
      break
    end
  end

  if not hasProcessing then
    return ExecBroker.PHASES.CLEANUP
  end

  return ExecBroker.PHASES.PROCESSING
end

--- Check the progress of a single processing job.
-- Returns "still_processing", "cleanup", or "fault".
-- @param addr    string  machine address
-- @param active  table   active job entry
-- @return string  status
function ExecBroker:_checkProcessingJob(addr, active)
  local machine = self._machines[addr]
  if not machine then
    active.manifest:fault("Machine node missing for " .. addr)
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end

  local manifest = active.manifest

  -- Poll hardware status
  local pollStatus = machine:pollHardware()

  -- Check for faults detected by MachineNode
  if machine:hasFault() then
    local flags = machine.maintenanceFlags
    self._reports[addr]:reportFault(flags.code, flags.description)
    manifest:fault("Machine fault: " .. (flags.description or "unknown"))
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end

  -- Check if machine is still active (has work in progress)
  -- In a real OC environment, we'd check getWorkProgress vs getWorkMaxProgress
  -- For testing, use the MachineNode's internal state

  -- Use maintenance check from HAL for comprehensive health
  local health = self._hal:checkMaintenanceState(machine)
  if health and health.faulted then
    -- Log all detected faults
    for _, fault in ipairs(health.faults) do
      self._reports[addr]:reportFault(fault.code, fault.description)
    end
    manifest:fault("Health check failed")
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end

  -- Check for completion: use tick counting for sub-second resolution
  -- (wall-clock age via os.time() doesn't advance in rapid tests)
  active._procTicks = (active._procTicks or 0) + 1

  -- Completion: machine inactive AND processing for >= 3 ticks (or age > 2s)
  -- When no proxy is set, assume machine is active (avoid premature completion)
  local isActive = (machine._proxy == nil)  -- default: active if no proxy
  if machine._proxy then
    local proxy = machine:_getProxy()
    if proxy and proxy.isMachineActive then
      isActive = proxy.isMachineActive()
    end
  end

  if not isActive and (active._procTicks >= 3 or manifest:age() > 2) then
    manifest:updateState("CLEANUP")
    active.phase = ExecBroker.PHASES.CLEANUP
    return "cleanup"
  end

  -- Check stale timeout
  if manifest:isStale() then
    manifest:fault("Processing timed out (stale)")
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end

  return "still_processing"
end

-- ===========================================================================
-- Phase 6: CLEANUP — Flush interfaces, release machines, transmit
-- ===========================================================================

--- Execute the CLEANUP phase for completed/faulted jobs.
-- Flushes ME interface, releases machine, updates stats.
-- @return string  next phase (BUFFERING or ALLOCATING)
function ExecBroker:_phaseCLEANUP()
  local cleaned = {}

  for addr, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.CLEANUP then
      self:_cleanupJob(addr, active)
      table.insert(cleaned, addr)
    end
  end

  -- Remove cleaned jobs from active set
  for _, addr in ipairs(cleaned) do
    self._activeJobs[addr] = nil
  end

  -- If queue has pending jobs, go to ALLOCATING; otherwise BUFFERING
  if self._queue:length() > 0 then
    return ExecBroker.PHASES.ALLOCATING
  end

  return ExecBroker.PHASES.BUFFERING
end

--- Clean up a single job: flush interface, release machine, update stats.
-- @param addr    string  machine address
-- @param active  table   active job entry
function ExecBroker:_cleanupJob(addr, active)
  local machine = self._machines[addr]
  local manifest = active.manifest

  -- Flush the ME interface (ghost-item cleanup)
  if machine then
    machine:flushInterface()
  end

  -- Release the machine
  if machine then
    local released = machine:releaseJob()
    if not released and machine:hasFault() then
      -- Faulted machine — clear fault and unlock
      machine:clearFault()
    end
  end

  -- Unbind hardware from manifest
  manifest:unbindHardware()

  -- Update stats
  if manifest.status == "CLEANUP" then
    manifest:updateState("COMPLETED")
    self._stats.jobsCompleted = self._stats.jobsCompleted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + manifest:age()
  elseif manifest.status == "FAULTED" then
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + manifest:age()
  end

  -- Log completion to maintenance report
  local report = self._reports[addr]
  if report then
    if manifest.faultReason then
      -- Already logged during fault detection
    else
      -- Log successful completion
      report:clearFault("Job " .. manifest.id .. " completed successfully")
    end
  end

  -- JIT memory: nil the manifest reference to assist GC
  active.manifest = nil
end

-- ===========================================================================
-- Telemetry
-- ===========================================================================

--- Build and transmit a telemetry payload to the Supervisor.
-- Fire-and-forget: never waits for a response.
-- Uses snapshot of current broker state.
function ExecBroker:_transmitTelemetry()
  local hwMatrix = {}
  for _, entry in ipairs(self._machineList) do
    if entry.node and type(entry.node.toTelemetry) == "function" then
      hwMatrix[entry.laneId] = entry.node:toTelemetry()
    else
      -- Fallback: emit bare identity data so telemetry still fires
      hwMatrix[entry.laneId] = {
        laneId  = entry.laneId,
        address = entry.address,
        status  = "unknown",
      }
    end
  end

  -- Collect alerts from all maintenance reports
  local alerts = {}
  for addr, report in pairs(self._reports) do
    if report.faultCode ~= 0 then
      table.insert(alerts, {
        machineId  = addr,
        code       = report.faultCode,
        message    = report:toHumanReadable(report.faultCode),
        timestamp  = os.time(),
        repairable = report.isRepairable,
      })
    end
  end

  -- Build payload (TelemetryPayload.build takes a single params table)
  local payload = self._M.TelemetryPayload.build({
    brokerId    = self._brokerId,
    queueLength = self._queue:length(),
    machines    = hwMatrix,
    alerts      = alerts,
    stats       = self._stats,
  })

  -- Transmit via modem if available
  if self._modem then
    payload:transmit(self._modem, self._telemetryPort)
  end

  -- Track last heartbeat
  self._lastHeartbeat = now()
end

-- ===========================================================================
-- Main event loop
-- ===========================================================================

--- Execute one tick of the broker main loop.
-- Advances the phase machine once. Call repeatedly from event loop.
-- @return boolean  true if the broker is still running
function ExecBroker:tick()
  if not self._running then
    return false
  end

  self._tickCount = self._tickCount + 1

  -- Check if it's time for a buffer poll (throttled by pollInterval)
  local cur = now()
  local timeSincePoll = cur - self._lastPollTime

  if timeSincePoll >= self._pollInterval then
    self._lastPollTime = cur

    if self._bufferFeeder then
      local bufferData = self._bufferFeeder()
      if type(bufferData) == "table" then
        if self._snapshot:update(bufferData) then
          if self._logger then self._logger:info("BUFFERING: snapshot stable, converting to manifest") end
          local manifest = self._snapshot:convertToManifest(0)
          if manifest then
            local hasItems  = manifest.inputs and manifest.inputs.items  and #manifest.inputs.items  > 0
            local hasFluids = manifest.inputs and manifest.inputs.fluids and #manifest.inputs.fluids > 0
            if hasItems or hasFluids then
              local job = self._M.JobManifest.new(manifest.id, manifest.inputs)
              job.priority  = manifest.priority  or 0
              job.status    = "PENDING"
              job.createdAt = manifest.createdAt or os.time()
              job.updatedAt = manifest.updatedAt or os.time()

              if self._queue:push(job) then
                if self._logger then self._logger:info("BUFFERING: job " .. job.id .. " queued") end
                self._snapshot:reset()
              else
                if self._logger then self._logger:warn("BUFFERING: queue full, job not pushed") end
              end
            else
              if self._logger then self._logger:info("BUFFERING: stable but empty, resetting snapshot") end
              self._snapshot:reset()
            end
          else
            if self._logger then self._logger:warn("BUFFERING: convertToManifest returned nil") end
          end
        else
          if self._logger then self._logger:debug("BUFFERING: snapshot not yet stable") end
        end
      else
        if self._logger then self._logger:warn("BUFFERING: bufferFeeder returned non-table: " .. type(bufferData)) end
      end
    else
      if self._logger then self._logger:warn("BUFFERING: no bufferFeeder configured") end
    end
  end

  -- Phase dispatch (advances state machine)
  local nextPhase = self._phase

  if self._phase == ExecBroker.PHASES.BUFFERING then
    if self._queue:length() > 0 then
      if self._logger then self._logger:info("BUFFERING: queue has jobs, transitioning to ALLOCATING") end
      nextPhase = self:_phaseALLOCATING()
    else
      nextPhase = self:_phaseBUFFERING()
    end
  elseif self._phase == ExecBroker.PHASES.LOGGING then
    nextPhase = self:_phaseLOGGING()
  elseif self._phase == ExecBroker.PHASES.ALLOCATING then
    nextPhase = self:_phaseALLOCATING()
  elseif self._phase == ExecBroker.PHASES.TRANSFERRING then
    nextPhase = self:_phaseTRANSFERRING()
  elseif self._phase == ExecBroker.PHASES.PROCESSING then
    nextPhase = self:_phasePROCESSING()
  elseif self._phase == ExecBroker.PHASES.CLEANUP then
    nextPhase = self:_phaseCLEANUP()
  end

  -- Record phase transition
  if nextPhase ~= self._phase then
    if self._logger then
      self._logger:info(string.format("Phase: %s -> %s (cycle %d)", self._phase, nextPhase, self._stats.cycles + 1))
    end
    self._phase = nextPhase
    self._stats.cycles = self._stats.cycles + 1
  end

  -- Telemetry broadcast (throttled by heartbeatInterval)
  local timeSinceHeartbeat = cur - self._lastHeartbeat
  if self._lastHeartbeat == 0 or timeSinceHeartbeat >= self._heartbeatInterval then
    self:_transmitTelemetry()
  end

  return true
end
--- Run the main event loop (cooperative multitasking via event.pull).
-- This is the production entry point. Uses the OC event system.
-- For testing without OC, call tick() directly in a loop.
-- @param maxTicks  number  optional max ticks (nil = run forever)
function ExecBroker:run(maxTicks)
  if self._logger then self._logger:info("Broker starting — phase: " .. self._phase) end

  -- Try to load OC event library
  local event = safeRequire("event")
  local computer = safeRequire("computer")

  local ticks = 0
  self._running = true

  while self._running do
    -- Execute one tick with error catching
    local ok, err = pcall(self.tick, self)
    if not ok then
      if self._logger then
        self._logger:error("Tick failed: " .. tostring(err))
      end
      break
    end
    if not err then break end

    ticks = ticks + 1
    if maxTicks and ticks >= maxTicks then break end

    -- Cooperative yield:
    -- If OC event system available, use event.pull with timeout
    -- Otherwise, yield via os.sleep(0) or os.execute("sleep 0.001")
    if event and self._eventPull then
      -- Custom event pull (injectable for testing)
      self._eventPull(self._pollInterval)
    elseif event and type(event.pull) == "function" then
      -- Real OC environment
      event.pull(self._pollInterval)
    else
      -- Vanilla Lua fallback
      os.execute("sleep " .. tostring(self._pollInterval))
    end
  end
end

--- Stop the broker main loop.
function ExecBroker:stop()
  self._running = false
end

-- ===========================================================================
-- Inspection / state queries
-- ===========================================================================

--- Get the current broker phase.
-- @return string  PHASES.*
function ExecBroker:getPhase()
  return self._phase
end

--- Get current broker stats.
-- @return table  { jobsCompleted, jobsFaulted, totalJobTime, cycles }
function ExecBroker:getStats()
  return {
    jobsCompleted = self._stats.jobsCompleted,
    jobsFaulted   = self._stats.jobsFaulted,
    totalJobTime  = self._stats.totalJobTime,
    cycles        = self._stats.cycles,
    tickCount     = self._tickCount,
    queueLength   = self._queue:length(),
    activeJobs    = self:_countActiveJobs(),
    phase         = self._phase,
  }
end

--- Count currently active jobs.
-- @return number
function ExecBroker:_countActiveJobs()
  local count = 0
  for _, _ in pairs(self._activeJobs) do
    count = count + 1
  end
  return count
end

--- Get the JobQueue reference (for inspection).
-- @return JobQueue
function ExecBroker:getQueue()
  return self._queue
end

--- Get a machine node by address.
-- @param addr  string
-- @return MachineNode or nil
function ExecBroker:getMachine(addr)
  return self._machines[addr]
end

--- Get all machine nodes.
-- @return table  address -> MachineNode
function ExecBroker:getMachines()
  return self._machines
end

--- Get the HAL instance.
-- @return HAL
function ExecBroker:getHAL()
  return self._hal
end

--- Get maintenance report for a machine.
-- @param addr  string
-- @return MaintenanceReport or nil
function ExecBroker:getReport(addr)
  return self._reports[addr]
end

--- Get all maintenance reports.
-- @return table  address -> MaintenanceReport
function ExecBroker:getReports()
  return self._reports
end

--- Get a summary snapshot of broker state for external inspection.
-- @return table
function ExecBroker:summarize()
  local machineStates = {}
  for _, entry in ipairs(self._machineList) do
    machineStates[entry.laneId] = entry.node:toTelemetry()
  end

  local activeSummaries = {}
  for addr, active in pairs(self._activeJobs) do
    activeSummaries[addr] = {
      jobId      = active.manifest and active.manifest.id,
      phase      = active.phase,
      assignedAt = active.assignedAt,
    }
  end

  return {
    brokerId      = self._brokerId,
    phase         = self._phase,
    stats         = self:getStats(),
    machines      = machineStates,
    activeJobs    = activeSummaries,
    queueSnapshot = self._queue:peek(),
  }
end

-- ===========================================================================
-- Entry point — run as standalone script
-- ===========================================================================
-- Detects direct execution vs require() via package.loaded.
if not package.loaded["src.exec_broker"] then
  local _ep_ok, _ep_err = pcall(function()
    local cfgPath = "/home/ae2es_broker.cfg"
    local cfgFile = io.open(cfgPath, "r")
    local config = nil

    if cfgFile then
      local raw = cfgFile:read("*a")  -- ← was missing entirely
      cfgFile:close()
      local chunk, loadErr = load(raw)
      if chunk then
        local ok2, result = pcall(chunk)
        if ok2 and type(result) == "table" then
          config = result
          print("Loaded config from " .. cfgPath)
        else
          print("Config parse error: " .. tostring(result))
        end
      else
        print("Config syntax error: " .. tostring(loadErr))
      end
    end  -- ← one end closes if cfgFile, not two

    if not config then
      print("No config found. Running config UI first...")
      local ConfigUI = require("src.config_ui")
      local ui = ConfigUI.new()
      config = ui:run()
      if not config then
        error("Configuration cancelled — cannot start broker without config")
      end
    end

    local broker = ExecBroker.new(config)
    print("Starting Exec Broker: " .. config.brokerId)
    broker:run()
  end)
  if not _ep_ok and _ep_err then
    print("Exec Broker error: " .. tostring(_ep_err))
  end
end

return ExecBroker
