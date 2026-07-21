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

-- Eager-load MachineNode at module scope — load failure crashes immediately
-- instead of silently creating plain-table fallback nodes.
local _MN = require("src.MachineNode")

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

local function stableMachineName(entry)
  return entry.machineName or entry.name or entry.laneId or
    entry.machineAddr or entry.address
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
--   enableAutoCrafting — boolean, opt into whitelisted ME auto-crafting
--   autoCraftInputs  — array of {name, amount, damage?, nbt?} desired buffer minimums
--   enableDiscovery  — boolean, opt into runtime GT machine discovery
--   minMachines      — number, minimum machines required when discovery starts
--   componentApi     — injectable OpenComputers component API for discovery
--   enablePersistence — opt into versioned crash-recovery persistence
--   persistence      — injectable persistence instance
--   persistenceDirectory — optional directory for persisted broker state
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
      node = _MN.new(machineAddr, {
        machineType = "gt_machine",
        hardwareAddress = machineAddr,
        laneId = laneId,
        useStateMachine = config.useStateMachine == true,
      })
      -- Verify the node got a proper metatable (debug: OC LuaJIT setmetatable issue)
      local mt = getmetatable(node)
      if mt == nil then
        error("MachineNode.new() returned a node without metatable for " .. tostring(laneId))
      end
    end

    machinesByLane[laneId] = node
    reports[laneId] = M.MaintenanceReport.new(laneId)
    table.insert(machineList, { laneId = laneId, address = machineAddr, node = node })
  end

  -- Sort for deterministic iteration
  table.sort(machineList, function(a, b) return a.laneId < b.laneId end)

  local staticMachineNames = {}
  local configuredMachines = config.staticMachines or machineEntries
  for _, lane in ipairs(configuredMachines) do
    local name = stableMachineName(lane)
    if type(name) == "string" and name ~= "" then
      staticMachineNames[name] = true
    end
  end

  -- Logger for diagnostics and error tracking
  local BrokerLogger = config.logger or safeRequire("src.broker_logger")
  local logger = nil
  if BrokerLogger and type(BrokerLogger.new) == "function" then
    logger = BrokerLogger.new(config.brokerId)
  end

  -- Always create a time-slice scheduler for cooperative multitasking
  local timeSliceScheduler = config.timeSliceScheduler
  if timeSliceScheduler == nil then
    local TimeSliceScheduler = safeRequire("src.timeslicescheduler")
    assert(TimeSliceScheduler ~= nil,
      "ExecBroker: time-slice scheduler could not be loaded")
    timeSliceScheduler = TimeSliceScheduler.new(config.timeSliceBudget)
  end
  assert(type(timeSliceScheduler.reset) == "function" and
    type(timeSliceScheduler.remaining) == "function",
    "ExecBroker: time-slice scheduler requires reset() and remaining()")

  -- Register singleton so all phases import, not receive, the scheduler
  local schedulerRegistry = safeRequire("src.scheduler_registry")
  if schedulerRegistry then schedulerRegistry.set(timeSliceScheduler) end

  local persistence = nil
  if config.enablePersistence == true then
    persistence = config.persistence
    if persistence == nil then
      local Persistence = safeRequire("lib.persistence")
      assert(Persistence ~= nil, "ExecBroker: persistence module could not be loaded")
      persistence = Persistence.new({ directory = config.persistenceDirectory })
    end
    assert(type(persistence.save) == "function" and type(persistence.load) == "function",
      "ExecBroker: persistence requires save() and load()")
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
    _staticMachineNames = staticMachineNames,
    _discoveredMachines = {},
    _componentApi       = config.componentApi,
    _enableDiscovery    = config.enableDiscovery == true,
    _minMachines        = config.minMachines,
    _meControllerAddr = config.meControllerAddr or "",
    _databaseAddr    = config.databaseAddr or "",
    _maxFluidSides   = config.maxFluidSides or 6,   -- ME Dual Interface fluid sides (0-5)
        _redstoneLockAddr = config.redstoneAddress or "",
        _redstoneLockSide = config.redstoneSide or 5,

    -- I/O
    _bufferFeeder    = config.bufferFeeder,
    _modem           = config.modem,
    _telemetryPort   = config.telemetryPort or 123,
    _controlPort     = config.controlPort or 124,
    _controlHandler  = nil,

    -- Timing
    _pollInterval     = config.pollInterval or 0.5,
    _heartbeatInterval = config.heartbeatInterval or 2.0,
    _dbSlots          = config.dbSlots or 9,
    _lastPollTime     = 0,
    _lastHeartbeat    = 0,
    _tickCount        = 0,
    _running          = true,
    _useStateMachine  = config.useStateMachine == true,
    _intakeBackoff    = nil,        -- sleep intake until this timestamp when stuck
    _timeSliceScheduler = timeSliceScheduler,
    _transferTimeout   = config.transferTimeout or 30,
    _enableAutoCrafting = config.enableAutoCrafting == true,
    _autoCraftInputs   = config.autoCraftInputs or {},
    _autoCraftPollCount = 0,
    _autoCraftFailures = {},
    _autoCraftCircuits = {},
    _enablePersistence = config.enablePersistence == true,
    _persistence       = persistence,
    _persistenceKey    = config.persistenceKey or ("broker-" .. config.brokerId:gsub("[^%w%._%-]", "_")),
    _lastPersistence   = 0,
    _persistenceInterval = config.persistenceInterval or 30,

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

  if self._enableDiscovery then
    local refreshed, err = self:refreshMachines()
    assert(refreshed, "ExecBroker: initial machine discovery failed: " .. tostring(err))
  end
  if self._minMachines ~= nil then
    assert(type(self._minMachines) == "number" and self._minMachines >= 0,
      "ExecBroker: minMachines must be a non-negative number")
    assert(#self._machineList >= self._minMachines,
      string.format("ExecBroker: requires minMachines=%d, found %d",
        self._minMachines, #self._machineList))
  end
  if self._enablePersistence then
    self:_restorePersistence()
  end

  -- Phase modules: each receives only the broker state it needs via constructor
  -- injection, eliminating the star topology.
  do
    local BufferingPhase    = safeRequire("src.phases.buffering")
    local LoggingPhase      = safeRequire("src.phases.logging")
    local AllocatingPhase   = safeRequire("src.phases.allocating")
    local TransferringPhase = safeRequire("src.phases.transferring")
    local ProcessingPhase   = safeRequire("src.phases.processing")
    local CleanupPhase      = safeRequire("src.phases.cleanup")

    assert(BufferingPhase and LoggingPhase and AllocatingPhase and
           TransferringPhase and ProcessingPhase and CleanupPhase,
      "ExecBroker: all phase modules required")

    self._bufferingPhase = BufferingPhase.new({
      bufferFeeder       = self._bufferFeeder,
      snapshot           = self._snapshot,
      logger             = self._logger,
      enableAutoCrafting = self._enableAutoCrafting,
      autoCraftInputs    = self._autoCraftInputs,
      meControllerAddr   = self._meControllerAddr,
      hal                = self._hal,
    })

    self._loggingPhase = LoggingPhase.new({
      snapshot    = self._snapshot,
      JobManifest = M.JobManifest,
      queue       = self._queue,
      logger      = self._logger,
    })

    self._allocatingPhase = AllocatingPhase.new({
      queue       = self._queue,
      machineList = self._machineList,
      activeJobs  = self._activeJobs,
      logger      = self._logger,
      hal         = self._hal,
      scheduler   = self._timeSliceScheduler,
    })

    self._transferringPhase = TransferringPhase.new({
      hal                 = self._hal,
      machineList         = self._machineList,
      machineTransposers  = self._machineTransposers,
      databaseAddr        = self._databaseAddr,
      meControllerAddr    = self._meControllerAddr,
      dbSlots             = self._dbSlots,
      activeJobs          = self._activeJobs,
      logger              = self._logger,
      scheduler           = self._timeSliceScheduler,
      transferTimeout     = self._transferTimeout,
      redstoneLockAddr    = self._redstoneLockAddr,
      redstoneLockSide    = self._redstoneLockSide,
      maxFluidSides       = self._maxFluidSides,
    })

    self._processingPhase = ProcessingPhase.new({
      hal                = self._hal,
      machines           = self._machines,
      machineTransposers = self._machineTransposers,
      reports            = self._reports,
      stats              = self._stats,
      activeJobs         = self._activeJobs,
      timeSliceScheduler = self._timeSliceScheduler,
      logger             = self._logger,
      clock              = now,
    })

    self._cleanupPhase = CleanupPhase.new({
      hal                = self._hal,
      machines           = self._machines,
      machineTransposers = self._machineTransposers,
      reports            = self._reports,
      stats              = self._stats,
      activeJobs         = self._activeJobs,
      databaseAddr       = self._databaseAddr,
      logger             = self._logger,
      scheduler          = self._timeSliceScheduler,
    })
  end

  return self
end

--- Add a discovered machine without altering explicitly configured lanes.
-- @param entry table component discovery entry
-- @param machineName string stable machine identity
-- @return string lane ID
function ExecBroker:_registerDiscoveredMachine(entry, machineName)
  local laneId = machineName
  if self._machines[laneId] then
    laneId = "discovered:" .. machineName
  end

  local node = self._M.MachineNode.new(entry.address, {
    machineType = entry.type or "gt_machine",
    hardwareAddress = entry.address,
    laneId = laneId,
    useStateMachine = self._useStateMachine,
  })
  self._machines[laneId] = node
  self._reports[laneId] = self._M.MaintenanceReport.new(laneId)
  table.insert(self._machineList, { laneId = laneId, address = entry.address, node = node })
  table.sort(self._machineList, function(a, b) return a.laneId < b.laneId end)
  self._discoveredMachines[machineName] = { laneId = laneId, address = entry.address }
  if type(self._hal.invalidateCache) == "function" then
    self._hal:invalidateCache(entry.address)
  end
  return laneId
end

local function discoveredName(componentApi, entry)
  if type(entry.machineName) == "string" and entry.machineName ~= "" then
    return entry.machineName
  end
  if type(componentApi) == "table" and type(componentApi.proxy) == "function" then
    local ok, proxy = pcall(componentApi.proxy, entry.address)
    if ok and type(proxy) == "table" then
      for _, methodName in ipairs({ "getMachineName", "getName" }) do
        local method = proxy[methodName]
        if type(method) == "function" then
          local named, name = pcall(method)
          if named and type(name) == "string" and name ~= "" then return name end
        end
      end
    end
  end
  return entry.address
end

--- Rescan GT machine components and merge them with static configuration.
-- Static entries are keyed by configured stable machine name and always win.
-- Missing dynamic machines are removed only when they have no active job.
-- @return boolean, number|string success plus current machine count or error
function ExecBroker:refreshMachines()
  if not self._enableDiscovery then return true, #self._machineList end

  local componentApi = self._componentApi or safeRequire("component")
  local ComponentDiscover = safeRequire("lib.component_discover")
  if not ComponentDiscover or not componentApi then
    return false, "component discovery is unavailable"
  end

  -- A refresh establishes a new component view. Drop cached handles first so
  -- newly registered and retained machines cannot keep a disconnected proxy.
  if type(self._hal.invalidateCache) == "function" then
    for _, machine in ipairs(self._machineList) do
      self._hal:invalidateCache(machine.address)
    end
  end

  local discovered = ComponentDiscover.discoverGtMachines(componentApi)
  local byName = {}
  for _, entry in ipairs(discovered) do
    local name = discoveredName(componentApi, entry)
    if not byName[name] then byName[name] = entry end
  end

  for name, record in pairs(self._discoveredMachines) do
    local latest = byName[name]
    if not latest or latest.address ~= record.address then
      if not self._activeJobs[record.laneId] then
        self._machines[record.laneId] = nil
        self._reports[record.laneId] = nil
        self._discoveredMachines[name] = nil
        for index = #self._machineList, 1, -1 do
          if self._machineList[index].laneId == record.laneId then
            table.remove(self._machineList, index)
          end
        end
        if type(self._hal.invalidateCache) == "function" then
          self._hal:invalidateCache(record.address)
        end
      end
    end
  end

  for name, entry in pairs(byName) do
    if not self._staticMachineNames[name] and not self._discoveredMachines[name] then
      self:_registerDiscoveredMachine(entry, name)
    end
  end

  return true, #self._machineList
end

-- ===========================================================================
-- Phase 1: BUFFERING — Monitor central buffer for stability
-- ===========================================================================

--- Execute the BUFFERING phase.
-- Polls buffer via bufferFeeder, updates BufferSnapshot.
-- If stable, converts to JobManifest and transitions to LOGGING.
-- @return string  next phase (LOGGING or BUFFERING)
--- Poll the central buffer via bufferFeeder and feed into snapshot.
-- ===========================================================================
-- Telemetry
-- ===========================================================================

--- Build and transmit a telemetry payload to the Supervisor.
-- Fire-and-forget: never waits for a response.
-- Uses snapshot of current broker state.
function ExecBroker:_transmitTelemetry()
  local hwMatrix = {}

  self._timeSliceScheduler:forEach(self._machineList, function(entry)
    if entry.node and type(entry.node.toTelemetry) == "function" then
      hwMatrix[entry.laneId] = entry.node:toTelemetry()
    else
      hwMatrix[entry.laneId] = {
        laneId  = entry.laneId,
        address = entry.address,
        status  = "unknown",
      }
    end
  end)

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

--- Compute the earliest time any processing machine is likely to complete.
-- Used by the intake backoff gate when allocating is stuck.
-- Returns nil when there are no processing jobs — nothing to wait for,
-- so keep polling in case a machine heals or becomes available.
-- @param now  number  current clock value
-- @return number|nil  timestamp after which to re-check, or nil for no backoff
function ExecBroker:_computeIntakeBackoff(now)
  local P = ExecBroker.PHASES
  local earliest = nil

  for _, active in pairs(self._activeJobs) do
    if active.phase == P.PROCESSING then
      if active._wakeTime and active._wakeTime > 0 then
        if not earliest or active._wakeTime < earliest then
          earliest = active._wakeTime
        end
      else
        -- Processing but no wakeTime (fallback polling) — short wait
        return now + 5
      end
    end
  end

  -- nil means no processing jobs — don't back off, keep polling
  return earliest
end

local PERSISTENCE_SCHEMA_VERSION = 1

local function persistedManifest(manifest)
  return {
    id = manifest.id or manifest.jobId,
    jobId = manifest.jobId or manifest.id,
    inputs = manifest.inputs or {},
    priority = manifest.priority or 0,
    createdAt = manifest.createdAt,
    updatedAt = manifest.updatedAt,
    metadata = manifest.metadata or {},
    faultReason = manifest.faultReason,
    assignedMachine = manifest.assignedMachine,
    state = manifest.state,
    status = manifest.status,
  }
end

function ExecBroker:_restoreManifest(snapshot, recoveryReason)
  if type(snapshot) ~= "table" or type(snapshot.id or snapshot.jobId) ~= "string" then
    return nil
  end
  local job = self._M.JobManifest.new(snapshot.id or snapshot.jobId, snapshot.inputs or {})
  job.priority = snapshot.priority or 0
  job.createdAt = snapshot.createdAt or os.time()
  job.updatedAt = os.time()
  job.metadata = snapshot.metadata or {}
  job.faultReason = snapshot.faultReason
  job.assignedMachine = nil
  job.status = "PENDING"
  job.state = "PENDING"
  if recoveryReason then
    job.metadata.persistenceRecovery = {
      retryable = true,
      reason = recoveryReason,
      recoveredAt = os.time(),
    }
  end
  return job
end

function ExecBroker:_persistencePayload()
  local queued = {}
  if type(self._queue.toPersistence) == "function" then
    for _, job in ipairs(self._queue:toPersistence()) do
      queued[#queued + 1] = persistedManifest(job)
    end
  end
  local active = {}
  for laneId, record in pairs(self._activeJobs) do
    active[#active + 1] = {
      laneId = laneId,
      phase = record.phase,
      manifest = persistedManifest(record.manifest),
    }
  end
  local reports = {}
  for laneId, report in pairs(self._reports) do
    if type(report.toPersistence) == "function" then
      reports[laneId] = report:toPersistence()
    end
  end
  return { queuedJobs = queued, activeJobs = active, maintenanceReports = reports }
end

function ExecBroker:_savePersistence()
  if not self._enablePersistence then return true end
  local saved, err = self._persistence:save(self._persistenceKey, {
    schemaVersion = PERSISTENCE_SCHEMA_VERSION,
    writtenAt = os.time(),
    payload = self:_persistencePayload(),
  })
  if saved then self._lastPersistence = now() end
  if not saved and self._logger then
    self._logger:warn("Persistence save failed: " .. tostring(err))
  end
  return saved, err
end

function ExecBroker:_restorePersistence()
  local envelope, err = self._persistence:load(self._persistenceKey, function(candidate)
    return candidate.schemaVersion == PERSISTENCE_SCHEMA_VERSION and
      type(candidate.payload) == "table", "unsupported persistence schema"
  end)
  if not envelope then
    if err ~= "not found" and self._logger then
      self._logger:warn("Persistence restore skipped: " .. tostring(err))
    end
    return false, err
  end

  local payload = envelope.payload
  for _, snapshot in ipairs(payload.queuedJobs or {}) do
    local job = self:_restoreManifest(snapshot)
    if not job or not self._queue:push(job) then
      if self._logger then self._logger:warn("Discarded invalid persisted queued job") end
    end
  end
  -- Active jobs are never restored into ALLOCATING, TRANSFERRING, PROCESSING,
  -- or CLEANUP. A crash can leave the physical transfer incomplete, so retry
  -- only through the normal queue path with an explicit recovery marker.
  for _, record in ipairs(payload.activeJobs or {}) do
    local job = self:_restoreManifest(record.manifest, "interrupted " .. tostring(record.phase) .. " transfer")
    if not job or not self._queue:push(job) then
      if self._logger then self._logger:warn("Discarded unrecoverable in-flight persisted job") end
    end
  end
  for laneId, snapshot in pairs(payload.maintenanceReports or {}) do
    local report = self._reports[laneId]
    if report and type(report.restorePersistence) == "function" then
      report:restorePersistence(snapshot)
    end
  end
  self._lastPersistence = now()
  return true
end

--- Execute one tick of the broker main loop.
-- Advances the phase machine once. Call repeatedly from event loop.
-- @return boolean  true if the broker is still running
function ExecBroker:tick()
  if not self._running then
    return false
  end

  self._tickCount = self._tickCount + 1

  -- The broker never asks the scheduler to sleep: when the framework is
  -- enabled it remains the only event.pull owner.  The scheduler is used only
  -- as a per-tick budget for real hot loops below.
  self._timeSliceScheduler:reset()

  -- Throttled buffer poll via the buffering phase module
  local cur = now()
  local pollResult = nil
  if cur - self._lastPollTime >= self._pollInterval then
    self._lastPollTime = cur
    pollResult = self._bufferingPhase:pollBuffer()
  end

  -- Back-end: service processing and cleanup every tick via phase modules.
  local P = ExecBroker.PHASES
  self._processingPhase:execute(P)
  self._cleanupPhase:execute(P)

  -- Front-end intake pipeline via phase modules
  local nextPhase = self._phase

  -- Intake backoff: when all machines are busy or unhealthy, sleep the
  -- intake pipeline until the earliest processing machine is likely done.
  -- Processing + cleanup always run — they're what frees up machines.
  if self._intakeBackoff and cur < self._intakeBackoff then
    goto intake_skipped
  end
  self._intakeBackoff = nil

  if self._phase == P.BUFFERING then
    nextPhase = self._bufferingPhase:execute(pollResult, P)
  elseif self._phase == P.LOGGING then
    nextPhase = self._loggingPhase:execute(P)
  elseif self._phase == P.ALLOCATING then
    nextPhase = self._allocatingPhase:execute(P)
  elseif self._phase == P.TRANSFERRING then
    nextPhase = self._transferringPhase:execute(P)
  end

  -- Record phase transition
  if nextPhase ~= self._phase then
    if self._logger then
      self._logger:info(string.format("Phase: %s -> %s (cycle %d)", self._phase, nextPhase, self._stats.cycles + 1))
    end
    self._phase = nextPhase
    self._stats.cycles = self._stats.cycles + 1
  end

  -- When stuck in ALLOCATING (no healthy machine), back off the intake
  -- pipeline until the earliest processing machine is likely done.
  -- If there are no processing jobs (nil), keep polling — a machine
  -- could heal or become available at any moment.
  if self._phase == P.ALLOCATING and nextPhase == P.ALLOCATING then
    self._intakeBackoff = self:_computeIntakeBackoff(cur)
  end

  ::intake_skipped::

  -- Drain deferred tasks (transfer sub-pipeline steps, etc.)
  self._timeSliceScheduler:processQueue()

  -- Telemetry broadcast (throttled by heartbeatInterval)
  local timeSinceHeartbeat = cur - self._lastHeartbeat
  if self._lastHeartbeat == 0 or timeSinceHeartbeat >= self._heartbeatInterval then
    self:_transmitTelemetry()
  end
  if self._enablePersistence and cur - self._lastPersistence >= self._persistenceInterval then
    self:_savePersistence()
  end

  return true
end

--- Apply a validated remote polling interval without exposing broker internals.
function ExecBroker:setPollInterval(interval)
  if type(interval) ~= "number" or interval < 0.1 or interval > 60 then
    return false, "poll interval outside safe bounds"
  end
  self._pollInterval = interval
  if self._logger then
    self._logger:warn("Remote control updated poll interval to " .. tostring(interval))
  end
  return true
end

--- Attach the opt-in control handler; launchers own the modem port lifecycle.
function ExecBroker:setControlHandler(handler)
  self._controlHandler = handler
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
      local signal = {self._eventPull(self._pollInterval)}
      if self._controlHandler and signal[1] == "modem_message" then
        self._controlHandler:handle(signal[3], signal[4], signal[6])
      end
    elseif event and type(event.pull) == "function" then
      -- Real OC environment
      local signal = {event.pull(self._pollInterval)}
      if self._controlHandler and signal[1] == "modem_message" then
        self._controlHandler:handle(signal[3], signal[4], signal[6])
      end
    else
      -- Vanilla Lua fallback
      os.execute("sleep " .. tostring(self._pollInterval))
    end
  end
  self:_savePersistence()
end

--- Stop the broker main loop.
function ExecBroker:stop()
  self:_savePersistence()
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
