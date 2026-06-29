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
    assert(type(itemSide) == "number",
      "itemSide must be a number, got " .. type(itemSide))
    assert(type(fluidSide) == "number",
      "fluidSide must be a number, got " .. type(fluidSide))
    local feederLogger = self._logger  -- capture for use inside closure
    self._bufferFeeder = function()
      local items, fluids = {}, {}
      -- Item buffer: inventory_controller uses getInventorySize + getStackInSlot
      if component and ibAddr ~= "" then
        local ok, proxy = pcall(component.proxy, ibAddr)
        if ok and proxy then
          local szOk, sz = pcall(function() return proxy.getInventorySize(itemSide) end)
          if szOk and type(sz) == "number" and sz > 0 then
            if feederLogger then
              feederLogger:debug(string.format(
                "BUFFERING: item controller inventorySize(%d)=%d", itemSide, sz))
            end
            for slot = 1, math.min(sz, 128) do
              local stOk, stack = pcall(function() return proxy.getStackInSlot(itemSide, slot) end)
              local count = 0
              if stack then
                if stack.size and stack.size > 0 then
                  count = stack.size
                else
                  local cntOk, cnt = pcall(function() return proxy.getSlotStackSize(itemSide, slot) end)
                  if cntOk and type(cnt) == "number" then count = cnt end
                end
              end
              -- Diagnostic: log every slot that has a name/label
              if feederLogger and stack and (stack.name or stack.label) then
                feederLogger:debug(string.format(
                  "BUFFERING: slot[%d] name=%s size=%s label=%s count=%d dmg=%d nbt=%s stOk=%s",
                  slot, tostring(stack.name or "nil"), tostring(stack.size or "nil"),
                  tostring(stack.label or "nil"), count,
                  tonumber(stack.damage or 0), tostring(stack.hasTag and "yes" or "no"),
                  tostring(stOk)))
              end
              if stOk and stack and count > 0 then
                local nbt = nil
                if stack.hasTag and stack.tag then
                  nbt = stack.tag
                end
                table.insert(items, {
                  name = stack.name or stack.label or "unknown",
                  label = stack.label or stack.name or "unknown",
                  size = count,
                  damage = stack.damage or 0,
                  nbt = nbt,
                })
              end
            end
          elseif feederLogger then
            feederLogger:debug(string.format(
              "BUFFERING: item controller getInventorySize(%d) returned szOk=%s sz=%s",
              itemSide, tostring(szOk), tostring(sz)))
          end
        elseif feederLogger then
          feederLogger:warn(string.format(
            "BUFFERING: component.proxy(%s) failed: ok=%s",
            ibAddr:sub(1,8).."...", tostring(ok)))
        end
      end
      -- Fluid buffer: tank_controller uses getTankCount + getFluidInTank
      if component and fbAddr ~= "" then
        local ok, proxy = pcall(component.proxy, fbAddr)
        if ok and proxy then
          local tcOk, tankCount = pcall(function() return proxy.getTankCount(fluidSide) end)
          if tcOk and type(tankCount) == "number" and tankCount > 0 then
            if feederLogger then
              feederLogger:debug(string.format(
                "BUFFERING: fluid controller tankCount(%d)=%d", fluidSide, tankCount))
            end
            for tank = 1, math.min(tankCount, 32) do
              local flOk, fluid = pcall(function() return proxy.getFluidInTank(fluidSide, tank) end)
              if flOk and fluid and fluid.label then
                local lvOk, level = pcall(function() return proxy.getTankLevel(fluidSide, tank) end)
                if feederLogger then
                  feederLogger:debug(string.format(
                    "BUFFERING: tank[%d] name=%s label=%s amount=%d",
                    tank, tostring(fluid.name or "nil"),
                    tostring(fluid.label), lvOk and (level or 0) or 0))
                end
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
      if feederLogger then
        feederLogger:debug(string.format(
          "BUFFERING: feeder poll — %d items, %d fluids",
          #items, #fluids))
      end
      return { items = items, fluids = fluids }
    end
    if self._logger then
      self._logger:info(string.format(
        "BUFFERING: auto-created feeder (itemSide=%d, fluidSide=%d, ibAddr=%s, fbAddr=%s)",
        itemSide, fluidSide,
        ibAddr ~= "" and ibAddr:sub(1,8).."..." or "(none)",
        fbAddr ~= "" and fbAddr:sub(1,8).."..." or "(none)"))
    end
  elseif self._logger then
    self._logger:warn("BUFFERING: no feeder and no buffer addresses configured")
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

  -- Perform transfer (multi-tick: store→stock→wait→pull→verify→clear)
  self:_transferForJob(target.address, self._activeJobs[target.address])

  local activeJob = self._activeJobs[target.address]
  if activeJob.phase == ExecBroker.PHASES.CLEANUP then
    return ExecBroker.PHASES.CLEANUP
  elseif activeJob.phase == ExecBroker.PHASES.TRANSFERRING then
    return ExecBroker.PHASES.TRANSFERRING
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

  -- Transition manifest to TRANSFERRING
  if manifest.status == "ALLOCATING" then
    manifest:updateState("TRANSFERRING")
  end

  -- Initialize transfer state on first tick
  if active._transferStep == nil then
    active._transferStep = "store"     -- steps: store → stock → wait → pull → verify → clear
    active._transferTick = 0
    active._transferDbSlots = { items = {}, fluids = {} }
  end

  local laneId = addr
  local laneCfg = self._machineTransposers[laneId]
  if not laneCfg then
    manifest:fault("No transposer config for lane " .. laneId)
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  local ifaceAddr = laneCfg.dualInterface
  if not ifaceAddr or ifaceAddr == "" then
    manifest:fault("No Dual Interface for lane " .. laneId)
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  -- Resolve transposer sides
  local ifaceSide  = self._hal:resolveSide("dualInterface") or laneCfg.pull or 0
  local inputSide  = self._hal:resolveSide("inputBus")      or laneCfg.push or 0
  local returnSide = self._hal:resolveSide("returnChest")    or laneCfg.return_ or 0

  if ifaceSide == 0 or inputSide == 0 then
    manifest:fault("Cannot resolve transfer sides for lane " .. laneId)
    active.phase = ExecBroker.PHASES.CLEANUP
    return
  end

  -- Save sides for CLEANUP
  active._laneSides = {
    ifaceSide  = ifaceSide,
    inputSide  = inputSide,
    returnSide = returnSide,
    ifaceAddr  = ifaceAddr,
  }

  local dbAddr = self._databaseAddr
  local hal = self._hal
  local inputs = manifest.inputs

  active._transferTick = active._transferTick + 1

  -- =========================================================================
  -- STEP: store — Write items/fluids to Database (JIT, max 9 item slots)
  -- =========================================================================
  if active._transferStep == "store" then
    if dbAddr and dbAddr ~= "" then
      -- Items: store in slots 1..N (max 9)
      if inputs.items then
        for i, item in ipairs(inputs.items) do
          if i > 9 then break end  -- hard cap: Database has 9 slots
          local name = item.name or item.label or "unknown"
          local damage = item.damage or 0
          local nbt = item.nbt or nil
          hal:storeDatabaseEntry(dbAddr, i, name, damage, nbt)
          active._transferDbSlots.items[i] = i
          if self._logger then
            self._logger:debug(string.format("TRANSFER: DB[%d] ← %s dmg=%d nbt=%s",
              i, name, damage, nbt and "yes" or "no"))
          end
        end
      end
      -- Fluids: store after items in remaining 9-slot pool
      if inputs.fluids then
        local fluidStart = #active._transferDbSlots.items + 1
        for i, fluid in ipairs(inputs.fluids) do
          local slot = fluidStart + i - 1
          if slot > 9 then break end
          local name = fluid.name or fluid.label or "unknown"
          hal:storeDatabaseEntry(dbAddr, slot, name, 0, nil)
          active._transferDbSlots.fluids[i] = slot
          if self._logger then
            self._logger:debug(string.format("TRANSFER: DB[%d] ← %s (fluid)", slot, name))
          end
        end
      end
    end
    active._transferStep = "stock"
    -- fall through to stock on same tick
  end

  -- =========================================================================
  -- STEP: stock — Configure Dual Interface from Database entries
  -- =========================================================================
  if active._transferStep == "stock" then
    if dbAddr and dbAddr ~= "" then
      -- Configure item stocking
      for i, dbSlot in ipairs(active._transferDbSlots.items) do
        local ok = hal:configureInterfaceStocking(ifaceAddr, i, dbAddr, dbSlot, 64)
        if ok and self._logger then
          self._logger:info(string.format("TRANSFER: lane %s iface[%d] ← DB[%d] x64", laneId, i, dbSlot))
        end
      end
      -- Configure fluid export (fire-and-forget)
      for _, dbSlot in ipairs(active._transferDbSlots.fluids) do
        local fluidSide = self._hal:resolveSide("fluidExport") or 0
        if fluidSide ~= 0 then
          hal:configureFluidExport(ifaceAddr, fluidSide, dbAddr, dbSlot)
          if self._logger then
            self._logger:info(string.format("TRANSFER: lane %s fluid export side %d ← DB[%d]", laneId, fluidSide, dbSlot))
          end
        end
      end
    end
    active._transferStep = "wait"
    -- yield to next tick; AE2 needs time to pull items from network
    return
  end

  -- =========================================================================
  -- STEP: wait — Poll interface inventory until AE2 has stocked items
  -- =========================================================================
  if active._transferStep == "wait" then
    if active._transferTick < 3 then
      -- Give AE2 at least ~1.5 seconds (3 ticks at 0.5s pollInterval)
      if self._logger then
        self._logger:debug(string.format("TRANSFER: lane %s waiting for AE2 (tick %d)...", laneId, active._transferTick))
      end
      return
    end

    -- Check if interface has items
    local stocked = true
    if #active._transferDbSlots.items > 0 then
      local sz = hal:checkSlotCount(ifaceSide, 1)
      if sz == nil or sz == 0 then
        stocked = false
        if self._logger then
          self._logger:debug(string.format("TRANSFER: lane %s interface slot 1 still empty (sz=%s)", laneId, tostring(sz)))
        end
      end
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
    if #active._transferDbSlots.items > 0 then
      local moved = hal:performInventoryTransfer(ifaceSide, inputSide, 64)
      if self._logger then
        self._logger:info(string.format("TRANSFER: lane %s iface→input moved %s items", laneId, tostring(moved or 0)))
      end
    end
    active._transferStep = "verify"
    -- yield to next tick for verification
    return
  end

  -- =========================================================================
  -- STEP: verify — Check interface is empty (all items moved to input bus)
  -- =========================================================================
  if active._transferStep == "verify" then
    local ifaceEmpty = true
    if #active._transferDbSlots.items > 0 then
      local remaining = hal:checkSlotCount(ifaceSide, 1)
      if remaining and remaining > 0 then
        ifaceEmpty = false
        if self._logger then
          self._logger:debug(string.format("TRANSFER: lane %s interface still has %d items, re-pulling", laneId, remaining))
        end
        -- Try pulling again
        hal:performInventoryTransfer(ifaceSide, inputSide, remaining)
        return  -- yield and re-verify next tick
      end
    end

    if ifaceEmpty then
      if self._logger then self._logger:info("TRANSFER: lane " .. laneId .. " interface empty, clearing") end
      active._transferStep = "clear"
      -- fall through to clear on same tick
    else
      return
    end
  end

  -- =========================================================================
  -- STEP: clear — Clear interface config + Database slots, then → PROCESSING
  -- =========================================================================
  if active._transferStep == "clear" then
    -- Clear interface item config slots
    for i = 1, #active._transferDbSlots.items do
      hal:clearInterfaceSlot(ifaceAddr, i)
    end
    -- Clear fluid export
    local fluidSide = self._hal:resolveSide("fluidExport") or 0
    if fluidSide ~= 0 then
      hal:clearFluidExport(ifaceAddr, fluidSide)
    end
    -- Clear Database slots
    if dbAddr and dbAddr ~= "" then
      for _, slot in ipairs(active._transferDbSlots.items) do
        hal:clearDatabaseSlot(dbAddr, slot)
      end
      for _, slot in ipairs(active._transferDbSlots.fluids) do
        hal:clearDatabaseSlot(dbAddr, slot)
      end
    end
    if self._logger then
      self._logger:info(string.format("TRANSFER: lane %s complete — iface+DB cleared, → PROCESSING", laneId))
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

--- Clean up a single job: extract leftovers, release machine, update stats.
-- Interface and Database clearing are handled in TRANSFERRING phase.
-- @param addr    string  machine address
-- @param active  table   active job entry
function ExecBroker:_cleanupJob(addr, active)
  local machine = self._machines[addr]
  local manifest = active.manifest

  -- 1. Extract leftover items from Machine Input Bus → Return Chest
  local laneSides = active._laneSides
  if laneSides and laneSides.returnSide and laneSides.inputSide and laneSides.returnSide ~= 0 then
    local leftover = self._hal:performInventoryTransfer(
      laneSides.inputSide, laneSides.returnSide, 64)
    if self._logger and leftover and leftover > 0 then
      self._logger:info(string.format(
        "CLEANUP: lane %s pulled %d leftover items from input bus to return chest",
        addr, leftover))
    end
  end

  -- 2. Release the machine
  if machine then
    local released = machine:releaseJob()
    if not released and machine:hasFault() then
      machine:clearFault()
    end
  end

  -- 3. Unbind hardware from manifest
  manifest:unbindHardware()

  -- 4. Update stats
  if manifest.status == "CLEANUP" then
    manifest:updateState("COMPLETED")
    self._stats.jobsCompleted = self._stats.jobsCompleted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + manifest:age()
  elseif manifest.status == "FAULTED" then
    self._stats.jobsFaulted = self._stats.jobsFaulted + 1
    self._stats.totalJobTime = self._stats.totalJobTime + manifest:age()
  end

  -- 5. Log to maintenance report
  local report = self._reports[addr]
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

  -- Check if it's time for a buffer poll (throttled by pollInterval)
  local cur = now()
  local timeSincePoll = cur - self._lastPollTime

  if timeSincePoll >= self._pollInterval then
    self._lastPollTime = cur

    if self._bufferFeeder then
      local bufferData = self._bufferFeeder()
      if type(bufferData) == "table" then
        if self._logger then
          local nItems = (bufferData.items and #bufferData.items) or 0
          local nFluids = (bufferData.fluids and #bufferData.fluids) or 0
          self._logger:debug(string.format("BUFFERING: feeder returned %d items, %d fluids", nItems, nFluids))
        end
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
