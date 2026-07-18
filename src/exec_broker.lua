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
ExecBroker.DEFAULT_MODULES = {
  JobManifest        = function() return safeRequire("src.jobmanifest") end,
  MachineNode        = function() return safeRequire("src.MachineNode") end,
  BufferSnapshot     = function() return safeRequire("src.BufferSnapshot") end,
  JobQueue           = function() return safeRequire("src.job_queue") end,
  HAL                = function() return safeRequire("src.hal") end,
  MaintenanceReport  = function() return safeRequire("src.maintenance_report") end,
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
--   meControllerAddr  — string, ME Controller address (central buffer; replaces item/fluid adapters)
--   databaseAddr     — string, OC database address (item stack data for transfer)
--   halConfig        — table, passed to HAL:new() (sideMap, cacheTTL, etc.)
--   queueSize        — number, max JobQueue size (default 64)
--   bufferFeeder     — function() -> bufferData, for reading item/fluid buffers
--   modem            — table, modem component for telemetry (optional)
--   telemetryPort    — number, modem port for broadcasts (default 123)
--   pollInterval     — number, seconds between buffer polls (default 0.5)
--   heartbeatInterval— number, seconds between telemetry broadcasts (default 2.0)
--   debounceWindow   — number, BufferSnapshot stability window (default 1.5)
--   useStateMachine  — boolean, opt into shared state-machine dispatch (default false)
-- @return ExecBroker instance
function ExecBroker.new(config)
  assert(config ~= nil, "ExecBroker requires a config table")
  assert(type(config.brokerId) == "string" and #config.brokerId > 0,
    "ExecBroker requires brokerId")
  assert(type(config.machines) == "table", "ExecBroker requires machines table")

  -- Load modules (config overrides default loaders)
  local M = {}
  for name, loader in pairs(ExecBroker.DEFAULT_MODULES) do
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
  local halConfig = config.halConfig or {}
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
          useStateMachine = config.useStateMachine == true,
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
    _meControllerAddr = config.meControllerAddr or "",
    _databaseAddr    = config.databaseAddr or "",
        _redstoneLockAddr = config.redstoneAddress or "",
        _redstoneLockSide = config.redstoneSide or 5,

    -- I/O
    _bufferFeeder    = config.bufferFeeder,
    _modem           = config.modem,
    _telemetryPort   = config.telemetryPort or 123,

    -- Timing
    _pollInterval     = config.pollInterval or 0.5,
    _heartbeatInterval = config.heartbeatInterval or 2.0,
    _dbSlots          = config.dbSlots or 9,
    _lastPollTime     = 0,
    _lastHeartbeat    = 0,
    _tickCount        = 0,
    _running          = true,
    _useStateMachine  = config.useStateMachine == true,

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

  if self._useStateMachine then
    local StateMachine = safeRequire("lib.state_machine")
    assert(StateMachine ~= nil, "ExecBroker: shared state machine could not be loaded")
    self._stateMachine = StateMachine.new(self._phase, self)
    self._stateMachine
      :addState(ExecBroker.PHASES.BUFFERING, {
        update = function(broker, pollResult)
          return broker:_phaseBUFFERING(pollResult)
        end,
      })
      :addState(ExecBroker.PHASES.LOGGING, {
        update = function(broker)
          return broker:_phaseLOGGING()
        end,
      })
      :addState(ExecBroker.PHASES.ALLOCATING, {
        update = function(broker)
          return broker:_phaseALLOCATING()
        end,
      })
      :addState(ExecBroker.PHASES.TRANSFERRING, {
        update = function(broker)
          return broker:_phaseTRANSFERRING()
        end,
      })
      :addState(ExecBroker.PHASES.PROCESSING, {})
      :addState(ExecBroker.PHASES.CLEANUP, {})
  end

  -- Auto-create bufferFeeder from ME Controller if not provided
  -- (config loaded from disk has address but no feeder function)
  if self._bufferFeeder == nil and self._meControllerAddr ~= "" then
    local meAddr = self._meControllerAddr
    if self._logger then
      self._logger:info(string.format(
        "BUFFERING: auto-created ME Controller feeder (addr=%s)",
        meAddr:sub(1,8).."..."))
    end
    self._bufferFeeder = function()
      local result, err = self._hal:getMEContents(meAddr)
      if not result then
        if self._logger then
            -- This now reports WHY it failed, not just that it returned nil
            self._logger:warn("BUFFERING: getMEContents failed: " .. (err or "Unknown error"))
        end
        return { items = {}, fluids = {} }
    end
      --self._logger:debug(string.format("BUFFERING: feeder poll — %d items, %d fluids",#result.items, #result.fluids))
      return result
    end
  elseif self._bufferFeeder == nil and self._logger then
    self._logger:warn("BUFFERING: no feeder and no ME Controller address configured")
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
--- Poll the central buffer via bufferFeeder and feed into snapshot.
-- Called from tick() when the poll throttle fires, NOT every tick.
-- @return boolean|nil  true if snapshot became stable, false if unstable, nil if skipped
function ExecBroker:_pollBuffer()
  if not self._bufferFeeder then return nil end
  local bufferData = self._bufferFeeder()
  if type(bufferData) ~= "table" then
    if self._logger then self._logger:warn("BUFFERING: bufferFeeder returned non-table: " .. type(bufferData)) end
    return nil
  end
  return self._snapshot:update(bufferData)
end

--- Execute the BUFFERING phase.
-- Uses pre-computed poll result from throttled _pollBuffer() call in tick().
-- When no poll ran this tick, just returns BUFFERING to wait for next throttled poll.
-- @param pollResult  boolean|nil  result from _pollBuffer() (nil = no poll this tick)
-- @return string  next phase (LOGGING or BUFFERING)
function ExecBroker:_phaseBUFFERING(pollResult)
  if not self._bufferFeeder then
    if self._logger then self._logger:warn("BUFFERING: no bufferFeeder configured") end
    return ExecBroker.PHASES.BUFFERING
  end

  -- No poll this tick — wait for throttle
  if pollResult == nil then
    return ExecBroker.PHASES.BUFFERING
  end

  --if self._logger then self._logger:info("BUFFERING: snapshot stable=" .. tostring(pollResult)) end

  if not pollResult then
    -- Still waiting for stability; yield and try again
    --if self._logger then self._logger:info("BUFFERING: snapshot not stable, waiting") end
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
  -- Don't start a new transfer while one is already using the Database
  for _, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.TRANSFERRING then
      return ExecBroker.PHASES.ALLOCATING  -- wait, try again next tick
    end
  end

  -- Pop next available job from queue
  local job = self._queue:popNextAvailable()
  if not job then
    -- No jobs pending — go back to buffering
    return ExecBroker.PHASES.BUFFERING
  end

  -- Find an available machine
  local target = nil
  for _, entry in ipairs(self._machineList) do
    if entry.node:isAvailable() and not self._activeJobs[entry.laneId] then
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
  --job:bindHardware(target.laneId)

  -- Track active job and perform transfer immediately (single-tick allocation)
  --self._activeJobs[target.address] = {
  self._activeJobs[target.laneId] = {
    manifest    = job,
    phase       = ExecBroker.PHASES.ALLOCATING,
    assignedAt  = os.time(),
  }

  -- Perform transfer (multi-tick: store→stock→wait→pull→verify→clear)
  --self:_transferForJob(target.address, self._activeJobs[target.address])
  --[[self:_transferForJob(target.laneId, self._activeJobs[target.laneId])

  --local activeJob = self._activeJobs[target.address]
  local activeJob = self._activeJobs[target.laneId]
  if activeJob.phase == ExecBroker.PHASES.CLEANUP then
    return ExecBroker.PHASES.CLEANUP
  elseif activeJob.phase == ExecBroker.PHASES.TRANSFERRING then
    return ExecBroker.PHASES.TRANSFERRING
  end]]--

  --return ExecBroker.PHASES.PROCESSING
  return ExecBroker.PHASES.TRANSFERRING
end

-- ===========================================================================
-- Phase 4: TRANSFERRING — Move items from buffer to machine interface
-- ===========================================================================

--- Execute the TRANSFERRING phase for all active jobs.
-- Uses HAL to transfer items from the central buffer to each allocated
-- machine's ME interface. Transitions to PROCESSING once all transfers complete.
-- @return string  next phase (PROCESSING or TRANSFERRING)
function ExecBroker:_phaseTRANSFERRING()
  --self._logger:info(string.format("TRANSFERRING PHASE"))
  -- Phase 1: Process jobs already in TRANSFERRING
  for laneId, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.TRANSFERRING then
      self:_transferForJob(laneId, active)
    end
  end

  -- Phase 2: Promote ALLOCATING jobs and transfer
  for laneId, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.ALLOCATING then
      active.phase = ExecBroker.PHASES.TRANSFERRING
      --self._logger:info(string.format("TRANSFERRING PHASE: ALLOCATING JOB TO TRANSFERRING"))
      self:_transferForJob(laneId, active)
    end
  end

  -- After all transfers, check if any jobs are still in TRANSFERRING or ALLOCATING
  --[[for _, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.TRANSFERRING or
       active.phase == ExecBroker.PHASES.ALLOCATING then
      return ExecBroker.PHASES.TRANSFERRING
    end
  end

  -- All jobs advanced to PROCESSING (or CLEANUP on error)
  return ExecBroker.PHASES.PROCESSING]]--
  -- Still transferring? Stay in this phase. All done? Free the pipeline
  -- for the next job. (CLEANUP jobs are handled by the async back-end.)
  for _, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.TRANSFERRING or
       active.phase == ExecBroker.PHASES.ALLOCATING then
      return ExecBroker.PHASES.TRANSFERRING
    end
  end
  return ExecBroker.PHASES.ALLOCATING
end

--- Transfer items for a specific job using Database + Dual Interface model.
-- Full pipeline per job:
--   1. JIT: Store manifest items/fluids in Database (max 9 slots, items only)
--   2. Configure Dual Interface to stock from Database
--   3. Wait for AE2 to deliver items to interface (multi-tick polling)
--   4. Transposer: Dual Interface → Machine Input Bus
--   5. Verify central buffer + interface are empty
--   6. Clear interface config + Database slots
--   7. → PROCESSING
-- Fluids: configure fluid export on interface (fire-and-forget, conduit auto-pulls)
-- @param addr    string  machine address (laneId)
-- @param active  table   active job entry
function ExecBroker:_transferForJob(addr, active)
  local manifest = active.manifest
  --self._logger:info(string.format("TRANSFERRING FOR JOB: %s", manifest.id))
  -- Transition manifest to TRANSFERRING
  if manifest.status == "ALLOCATING" then
    manifest:updateState("TRANSFERRING")
    self._logger:info(string.format("TRANSFERRING FOR JOB: %s UPDATED TO TRANSFERRING", manifest.id))
  end

  -- Initialize transfer state on first tick
  if active._transferStep == nil then
    active._transferStep = "store"     -- steps: store → stock → wait → pull → verify → clear
    active._transferTick = 0
    active._transferDbSlots = { items = {}, fluids = {} }
  end

  -- addr is the machine hardware address; resolve to laneId for config lookup
  local laneId = addr
  for _, entry in ipairs(self._machineList) do
    if entry.address == addr then
      laneId = entry.laneId
      break
    end
  end
  local laneCfg = self._machineTransposers[laneId]
  if not laneCfg then
    manifest:fault("No transposer config for lane " .. laneId)
    self._logger:info(string.format("TRANSFERRING FOR JOB: %s FAULTED: No transposer config for lane %s", manifest.id, laneId))
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  local ifaceAddr = laneCfg.dualInterface
  if not ifaceAddr or ifaceAddr == "" then
    manifest:fault("No Dual Interface for lane " .. laneId)
    self._logger:info(string.format("TRANSFERRING FOR JOB: %s FAULTED: No Dual Interface for lane %s", manifest.id, laneId))
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  -- Resolve transposer sides
  local transposerAddr = laneCfg.transposerAddr
  local ifaceSide  = laneCfg.pull
  local inputSide  = laneCfg.push 
  local returnSide = laneCfg.return_ 

  if ifaceSide == nil or inputSide == nil then
    manifest:fault("Cannot resolve transfer sides for lane " .. laneId)
    self._logger:info(string.format("TRANSFERRING FOR JOB: %s FAULTED: Cannot resolve transfer sides for lane %s", manifest.id, laneId))
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  local dbAddr = self._databaseAddr
  local hal = self._hal
  local inputs = manifest.inputs

  active._transferTick = active._transferTick + 1

  -- =========================================================================
  -- STEP: store — Write items/fluids to Database (shared sequential pool)
  -- Both items and fluids use CommonNetworkAPI.store() which handles
  -- zlib-BNBT → JSON NBT conversion correctly.
  -- =========================================================================
  if active._transferStep == "store" then
    if dbAddr and dbAddr ~= "" then
      local meAddr = self._meControllerAddr
      local dbSlot = 1

      -- Items: CommonNetworkAPI.store() for correct NBT encoding
      if inputs.items then
        for _, item in ipairs(inputs.items) do
          if dbSlot > self._dbSlots then break end
          local filter = { name = item.name or "unknown", damage = item.damage or 0 }
          local ok, err = hal:storeNetworkEntry(meAddr, filter, dbAddr, dbSlot)
          if ok then
            self._logger:info(string.format(
              "TRANSFERRING FOR JOB: %s STORED %s IN DATABASE FOR LANE %s",
              manifest.id, item.label, laneId))
            table.insert(active._transferDbSlots.items, {
              dbSlot    = dbSlot,
              fluidDrop = nil,
              name      = item.name,
              label     = item.label,
            })
            dbSlot = dbSlot + 1
          else
            self._logger:info(string.format(
              "TRANSFERRING FOR JOB: %s FAILED TO STORE %s IN DATABASE FOR LANE %s: %s",
              manifest.id, item.name, laneId, tostring(err)))
            manifest:fault("Failed to store item in Database for lane " .. laneId)
            active.phase = ExecBroker.PHASES.CLEANUP
            return
          end
        end
      end

      -- Fluids: CommonNetworkAPI.store() for correct NBT encoding
      if inputs.fluids then
        for _, fluid in ipairs(inputs.fluids) do
          if dbSlot > self._dbSlots then break end
          -- Filter by the discretized drop label ("drop of <fluid>")
          local filter = { label = "drop of " .. fluid.label }
          local ok, err = hal:storeNetworkEntry(meAddr, filter, dbAddr, dbSlot)
          if ok then
            self._logger:info(string.format(
              "TRANSFERRING FOR JOB: %s STORED %s IN DATABASE FOR LANE %s",
              manifest.id, fluid.label, laneId))
            table.insert(active._transferDbSlots.items, {
              dbSlot    = dbSlot,
              fluidDrop = true,
              name      = fluid.name,
              label     = fluid.label,
            })
            dbSlot = dbSlot + 1
          else
            self._logger:info(string.format(
              "TRANSFERRING FOR JOB: %s FAILED TO STORE %s IN DATABASE FOR LANE %s: %s",
              manifest.id, fluid.name, laneId, tostring(err)))
            manifest:fault("Failed to store fluid in Database for lane " .. laneId)
            active.phase = ExecBroker.PHASES.CLEANUP
            return
          end
        end
      end

      self._logger:info(string.format(
        "TRANSFERRING FOR JOB: %s STORED %d ITEMS/FLUIDS IN DATABASE",
        manifest.id, #active._transferDbSlots.items))
    end
    active._transferStep = "stock"
    -- fall through to stock on same tick
  end

  -- =========================================================================
  -- STEP: stock — Configure Dual Interface from Database entries
  -- slot.fluidDrop decides item-stock (nil) vs fluid-export (truthy).
  -- =========================================================================
  if active._transferStep == "stock" then
    local fluidCount = 0  -- assign channel 0,1,2,3,4,5 per fluid
    for _, slot in ipairs(active._transferDbSlots.items) do

      if slot.fluidDrop then
        if fluidCount >= 6 then break end  -- ponytail: cap at 6 sides
        local ok, err = hal:configureFluidExport(
          ifaceAddr,
          fluidCount,   -- dynamic: 0 for 1st fluid, 1 for 2nd, etc.
          dbAddr,
          slot.dbSlot
        )
        slot.fluidSide = fluidCount  -- remember for clear step

        if not ok then
          manifest:fault("Fluid config failed: " .. tostring(err))
          active.phase = ExecBroker.PHASES.CLEANUP
          return
        end
        fluidCount = fluidCount + 1

      else
        local ok = hal:configureInterfaceStocking(
          ifaceAddr,
          slot.dbSlot,
          dbAddr,
          slot.dbSlot,
          64
        )

        if not ok then
          manifest:fault("Stock config failed")
          active.phase = ExecBroker.PHASES.CLEANUP
          return
        end
      end
    end

    active._transferStep = "wait"
    return
  end
  -- =========================================================================
  -- STEP: wait — Poll interface inventory until AE2 has stocked items
  -- =========================================================================
  if active._transferStep == "wait" then
    if active._transferTick < 6 then
      -- Give AE2 at least ~3 seconds (6 ticks at 0.5s pollInterval)
      if self._logger then
        self._logger:debug(string.format("TRANSFER: lane %s waiting for AE2 (tick %d)...", laneId, active._transferTick))
      end
      return
    end

    -- Check if interface has items
    local stocked = true
    if #active._transferDbSlots.items > 0 then
      local ok, result = self._hal:checkInterfaceStocked(ifaceAddr, #active._transferDbSlots.items)
      if self._logger then
        self._logger:debug(string.format("TRANSFER: lane %s interface stocked: %s", laneId, ok))
      end
      stocked = ok
    end

    if stocked then
      active._transferStep = "pull"
      if self._logger then self._logger:info("TRANSFER: lane " .. laneId .. " AE2 stocked interface, pulling to input bus") end
      -- fall through to pull on same tick
    elseif active._transferTick > 20 then
      -- Timeout (~10 seconds) — fault the job
      manifest:fault("AE2 stocking timeout for lane " .. laneId)
      active.phase = ExecBroker.PHASES.CLEANUP
      return
    else
      return  -- keep waiting
    end
  end

  -- =========================================================================
  -- STEP: pull — Transposer: Dual Interface → Machine Input Bus
  -- =========================================================================
  if active._transferStep == "pull" then
    -- Check if there are actually items scheduled for this lane
    if active._transferDbSlots and active._transferDbSlots.items and #active._transferDbSlots.items > 0 then
      -- Execute the pull
      local contents = hal:getInventoryContents(transposerAddr, ifaceSide)
      if contents then
        local moved = hal:drainInventory(transposerAddr, ifaceSide, inputSide)
        self._logger:info(string.format("TRANSFER: lane %s iface→input moved %s items", laneId, tostring(moved)))
        if moved and moved > 0 then
          active._lastMoved = moved
          active._transferAttempts = nil
        else
          active._transferAttempts = (active._transferAttempts or 0) + 1
          if active._transferAttempts >= 3 then
            local message = string.format(
              "TRANSFER: lane %s moved zero items after %d attempts; faulting job",
              laneId, active._transferAttempts)
            manifest:fault(message)
            active.phase = ExecBroker.PHASES.CLEANUP
            if self._logger then self._logger:warn(message) end
          end
          -- Keep the pull step for the next broker tick.  This is deliberately
          -- tick-driven rather than HAL:transferWithRetry's sleeping retry loop.
          return
        end
      end
    end

    -- Yield this tick and verify on the next
    active._transferStep = "verify"
    return
  end
  -- =========================================================================
  -- STEP: verify — Check interface is empty (all items moved to input bus)
  -- =========================================================================
  if active._transferStep == "verify" then
    
    if active._lastMoved and active._lastMoved > 0 then
      if self._logger then 
        self._logger:info("TRANSFER: lane " .. laneId .. " transfer complete, advancing to clear") 
      end
      
      -- Transfer successful! Clean up and move to the next phase
      active._lastMoved = nil 
      active._transferStep = "clear"
      return
      
    else
      -- 0 items moved. Interface was empty, starved, or jammed.
      if self._logger then 
        self._logger:warn("TRANSFER: lane " .. laneId .. " zero items moved during pull. Advancing to clear.") 
      end
      
      -- Decide how your system handles a dry pull here. 
      -- Advancing to "clear" prevents the system from hanging forever.
      active._lastMoved = nil
      active._transferStep = "clear" 
      return
    end
  end

  -- =========================================================================
  -- STEP: clear — Clear interface config + Database slots, then → PROCESSING
  -- =========================================================================
  if active._transferStep == "clear" then
    -- Clear interface config and fluid export per tracked slot
    for _, slot in ipairs(active._transferDbSlots.items) do
      if slot.fluidDrop then
        hal:clearFluidExport(ifaceAddr, slot.fluidSide or 0)
      else
        hal:clearInterfaceSlot(ifaceAddr, slot.dbSlot)
      end
    end
    -- Clear Database slots
    if dbAddr and dbAddr ~= "" then
      for _, slot in ipairs(active._transferDbSlots.items) do
        hal:clearDatabaseSlot(dbAddr, slot.dbSlot)
      end
    end
    if self._logger then
      self._logger:info(string.format("TRANSFER: lane %s complete — iface+DB cleared, → PROCESSING", laneId))
    end
    
    -- Pulse redstone lock to signal lane is free for next job
    if self._redstoneLockAddr and self._redstoneLockAddr ~= "" then
      local ok, err = self._hal:pulseRedstoneLock(self._redstoneLockAddr, self._redstoneLockSide, 0.1)
      if not ok then
        self._logger:warn(string.format("TRANSFER: lane %s redstone pulse failed: %s", laneId, tostring(err)))
      else
        self._logger:info(string.format("TRANSFER: lane %s redstone pulse successful", laneId))
      end
    end
    manifest:updateState("PROCESSING")
    active.phase = ExecBroker.PHASES.PROCESSING
  end
end
-- ===========================================================================
-- Phase 5: PROCESSING — Monitor machine until job completes
-- ===========================================================================

--- Execute the PROCESSING phase for all active jobs.
-- Polls hardware, detects completion and faults.
-- @return string  next phase (CLEANUP, PROCESSING, or ALLOCATING)
function ExecBroker:_phasePROCESSING()
  for laneId, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.PROCESSING then
      self:_checkProcessingJob(laneId, active)
    end
  end
end


--- Check the progress of a single processing job.
-- Returns "still_processing", "cleanup", or "fault".
-- @param addr    string  machine address
-- @param active  table   active job entry
-- @return string  status
function ExecBroker:_checkProcessingJob(laneId, active)
  --local machine = self._machines[addr]
  local machine = self._machines[laneId]
  if not machine then
    if self._logger then
      self._logger:error("PROCESSING: lane " .. laneId .. " machine node missing — faulting job " .. active.manifest.id)
    end
    active.manifest:fault("Machine node missing for " .. laneId)
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end

  local manifest = active.manifest

  -- Poll hardware status via HAL
  local pollStatus = self._hal:pollMachineHardware(machine)

  -- Check for faults detected by MachineNode
  if machine:hasFault() then
    local flags = machine.maintenanceFlags
    if self._logger then
      self._logger:warn("PROCESSING: lane " .. laneId .. " machine fault: " .. (flags.description or "unknown"))
    end
    --self._reports[addr]:reportFault(flags.code, flags.description)
    self._reports[laneId]:reportFault(flags.code, flags.description)
    manifest:fault("Machine fault: " .. (flags.description or "unknown"))
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end

  -- Check if machine is still active (has work in progress)
  -- In a real OC environment, we'd check getWorkProgress vs getWorkMaxProgress
  -- For testing, use the MachineNode's internal state

  -- Use maintenance check from HAL for comprehensive health
  local laneCfg = self._machineTransposers[laneId]
  if laneCfg then
    local health = self._hal:checkMaintenanceState(machine, laneCfg.transposerAddr, laneCfg.pull)
    local report = self._reports[laneId]
    if health and report then
      for _, advisory in ipairs(health.advisories or {}) do
        report:reportAdvisory(advisory.code, advisory.description)
      end
    end
    if health and health.faulted then
      if self._logger then
        self._logger:warn("PROCESSING: lane " .. laneId .. " health check found " .. tostring(#health.faults) .. " faults")
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
      -- Sensor maintenance is reported but intentionally does not block job
      -- execution or future allocation during this trial.
      if hasBlockingFault then
        manifest:fault("Health check failed")
        self._stats.jobsFaulted = self._stats.jobsFaulted + 1
        active.phase = ExecBroker.PHASES.CLEANUP
        return "fault"
      end
    end
  end
  if self._logger then
    self._logger:info(string.format("PROCESSING: lane %s is still processing (procTicks=%d, age=%d)",laneId, active._procTicks or 0, math.floor(manifest:age())))
  end

  -- Check for completion: use tick counting for sub-second resolution
  -- (wall-clock age via os.time() doesn't advance in rapid tests)
  active._procTicks = (active._procTicks or 0) + 1

  -- Completion: machine inactive AND processing for >= 2 ticks (or age > 2s)
  -- Use HAL:getProxy() to reach the GT machine component.
  local isActive = true  -- default: active if no proxy available at all
  local proxy, proxyErr = self._hal:getProxy(machine.hardwareAddress)
  if not proxy then
    if self._logger then
      self._logger:warn("PROCESSING: lane " .. laneId .. " HAL:getProxy failed: " .. tostring(proxyErr))
    end
    manifest:fault("Machine proxy error: " .. tostring(proxyErr))
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    active.phase = ExecBroker.PHASES.CLEANUP
    return "fault"
  end
  if proxy and proxy.isMachineActive then
    isActive = proxy.isMachineActive()
  end

  if self._logger then
    self._logger:info(string.format("PROCESSING: lane %s proxy=%s isActive=%s procTicks=%d age=%d",
      laneId, proxy and "yes" or "nil", tostring(isActive), active._procTicks, math.floor(manifest:age())))
  end

  if not isActive and (active._procTicks >= 2 or math.floor(manifest:age()) > 2) then
    if self._logger then
      self._logger:info("PROCESSING: lane " .. laneId .. " job " .. manifest.id .. " complete → CLEANUP")
    end
    manifest:updateState("CLEANUP")
    active.phase = ExecBroker.PHASES.CLEANUP
    return "cleanup"
  end

  -- Check stale timeout
  if manifest:isStale() then
    if self._logger then
      self._logger:warn("PROCESSING: lane " .. laneId .. " job " .. manifest.id .. " timed out (stale)")
    end
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

  for laneId, active in pairs(self._activeJobs) do
    if active.phase == ExecBroker.PHASES.CLEANUP then
      self:_cleanupJob(laneId, active)
      table.insert(cleaned, laneId)
    end
  end

  -- Remove cleaned jobs from active set
  for _, laneId in ipairs(cleaned) do
    self._activeJobs[laneId] = nil
  end

  if self._logger and #cleaned > 0 then
    self._logger:info(string.format("CLEANUP: released %d lanes", #cleaned))
  end

  -- ponytail: back-end runs every tick; return value is ignored
end

--- Clean up a single job: extract leftovers, release machine, update stats.
-- Interface and Database clearing are handled in TRANSFERRING phase.
-- @param addr    string  machine address
-- @param active  table   active job entry
function ExecBroker:_cleanupJob(laneId, active)
  local machine = self._machines[laneId]
  local manifest = active.manifest

  -- 1. Extract leftover items from Machine Input Bus → Return Chest
  local laneCfg = self._machineTransposers[laneId]
  if laneCfg and laneCfg.transposerAddr and laneCfg.push and laneCfg.return_ then
    local leftover = self._hal:drainInventory(laneCfg.transposerAddr, laneCfg.push, laneCfg.return_)
    if leftover and leftover > 0 then
      if self._logger then
        self._logger:info(string.format(
          "CLEANUP: lane %s pulled %d leftover items from input bus to return chest",
          laneId, leftover))
      end
    end
  elseif self._logger then
    self._logger:debug("CLEANUP: lane " .. laneId .. " no transposer config, skipping drain")
  end

  -- 2. Release the machine
  if machine then
    local released = machine:releaseJob()
    if not released then
      if machine:hasFault() then
        if self._logger then
          self._logger:warn("CLEANUP: lane " .. laneId .. " releaseJob failed (faulted), clearing fault")
        end
        machine:clearFault()
      elseif self._logger then
        self._logger:warn("CLEANUP: lane " .. laneId .. " releaseJob failed (unexpected state)")
      end
    end
  end

  -- 3. Unbind hardware from manifest
  manifest:unbindHardware()

  -- 4. Update stats
  if manifest.status == "CLEANUP" then
    manifest:updateState("COMPLETED")
    self._stats.jobsCompleted = self._stats.jobsCompleted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + math.floor(manifest:age())
    if self._logger then
      self._logger:info(string.format(
        "CLEANUP: lane %s job %s COMPLETED (age=%ds)",
        laneId, manifest.id, math.floor(manifest:age())))
    end
  elseif manifest.status == "FAULTED" then
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + math.floor(manifest:age())
    if self._logger then
      self._logger:warn(string.format(
        "CLEANUP: lane %s job %s FAULTED: %s",
        laneId, manifest.id, manifest.faultReason or "unknown"))
    end
  end

  -- 5. Log to maintenance report
  local report = self._reports[laneId]
  if report then
    if not manifest.faultReason then
      report:clearFault("Job " .. manifest.id .. " completed successfully")
    end
  end

  -- 6. Nil manifest reference for GC
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

  -- Throttled buffer poll (not every tick — respects pollInterval)
  local cur = now()
  local pollResult = nil
  if cur - self._lastPollTime >= self._pollInterval then
    self._lastPollTime = cur
    pollResult = self:_pollBuffer()
  end

  -- Async back-end: service any jobs past TRANSFERRING every tick,
  -- independent of what the front-end pipeline (self._phase) is doing.
  self:_phasePROCESSING()
  self:_phaseCLEANUP()

  -- Serialized front-end intake pipeline. The shared state machine is opt-in
  -- until its behavior has soaked alongside the legacy dispatcher.
  local nextPhase = self._phase
  if self._stateMachine then
    nextPhase = self._stateMachine:update(pollResult)
  else
    if self._phase == ExecBroker.PHASES.BUFFERING then
      nextPhase = self:_phaseBUFFERING(pollResult)
    elseif self._phase == ExecBroker.PHASES.LOGGING then
      nextPhase = self:_phaseLOGGING()
    elseif self._phase == ExecBroker.PHASES.ALLOCATING then
      nextPhase = self:_phaseALLOCATING()
    elseif self._phase == ExecBroker.PHASES.TRANSFERRING then
      nextPhase = self:_phaseTRANSFERRING()
    end
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

return ExecBroker
