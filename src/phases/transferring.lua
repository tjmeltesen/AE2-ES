--[[
transferring.lua -- Phase 4: TRANSFERRING (extracted from exec_broker.lua)

Manages the 6-step transfer sub-pipeline (store → stock → wait →
pull → verify → clear) that moves items/fluids from the central ME
buffer through a Dual Interface to the machine's input bus.

Dependencies: receives HAL, machineList, machineTransposers,
databaseAddr, meControllerAddr, dbSlots, activeJobs, logger,
and optional coroutine/framework hooks as constructor arguments.
]]--

local schedulerRegistry = require("src.scheduler_registry")
local TransferringPhase = {}
TransferringPhase.__index = TransferringPhase

local function now()
  local ok, computer = pcall(require, "computer")
  if ok and type(computer.uptime) == "function" then
    return computer.uptime()
  end
  return os.time() + (os.clock() % 1)
end

function TransferringPhase.new(context)
  assert(type(context.hal) == "table",
    "TransferringPhase requires hal (HAL)")
  assert(type(context.machineList) == "table",
    "TransferringPhase requires machineList")
  assert(type(context.machineTransposers) == "table",
    "TransferringPhase requires machineTransposers table")
  assert(type(context.activeJobs) == "table",
    "TransferringPhase requires activeJobs table")

  return setmetatable({
    _hal                 = context.hal,
    _machineList         = context.machineList,
    _machineTransposers  = context.machineTransposers,
    _databaseAddr        = context.databaseAddr or "",
    _meControllerAddr    = context.meControllerAddr or "",
    _dbSlots             = context.dbSlots or 9,
    _activeJobs          = context.activeJobs,
    _logger              = context.logger,
    _transferTimeout     = context.transferTimeout or 30,
    _redstoneLockAddr    = context.redstoneLockAddr or "",
    _redstoneLockSide    = context.redstoneLockSide or 5,
    _maxFluidSides       = context.maxFluidSides or 6,
  }, TransferringPhase)
end

--- Execute one tick of the transferring phase.
-- @param phases table of phase name constants
-- @return string next phase
function TransferringPhase:execute(phases)
  local sched = schedulerRegistry.get()

  -- Promote ALLOCATING jobs
  sched:forEachPair(self._activeJobs, function(_, active)
    if type(active) ~= "table" then return end
    if active.phase == phases.ALLOCATING then active.phase = phases.TRANSFERRING end
  end)

  sched:forEachPair(self._activeJobs, function(laneId, active)
    if type(active) ~= "table" then return end
    if active.phase == phases.TRANSFERRING then
      if self:_transferTimedOut(laneId, active, phases) then
      elseif not self:_scheduleCoroutine(laneId, active) then
        self:_transferForJob(laneId, active, phases)
      end
    end
  end)

  local hasPending = false
  sched:forEachPair(self._activeJobs, function(_, active)
    if hasPending then return end
    if type(active) ~= "table" then return end
    if active.phase == phases.TRANSFERRING or active.phase == phases.ALLOCATING then
      hasPending = true
    end
  end)
  if hasPending then return phases.TRANSFERRING end
  return phases.ALLOCATING
end

-- =========================================================================
-- Timeout guard
-- =========================================================================

function TransferringPhase:_transferTimedOut(laneId, active, phases)
  local startedAt = active._transferStartedAt
  if not startedAt then
    active._transferStartedAt = now()
    return false
  end
  if now() - startedAt <= self._transferTimeout then return false end

  active.manifest:fault(string.format(
    "Transfer timed out after %ds for lane %s",
    self._transferTimeout, laneId))
  active.phase = phases.CLEANUP
  active._transferThread = nil
  active._transferDeferred = nil
  active._transferStep = nil
  if self._logger then
    self._logger:warn("Transfer timed out for lane " .. laneId)
  end
  return true
end

-- =========================================================================
-- Deferred task scheduling (uses TimeSliceScheduler)
-- =========================================================================

function TransferringPhase:_scheduleCoroutine(laneId, active)
  -- Deferred task: advance one sub-pipeline step per tick via scheduler:defer()
  if active._transferDeferred then return true end

  local selfRef = self
  local sched = schedulerRegistry.get()
  local function step()
    selfRef:_transferForJob(laneId, active, {})
    -- Re-defer only if the sub-pipeline hasn't finished yet
    if active._transferStep and selfRef._activeJobs[laneId] == active
       and active.phase == selfRef._activeJobs[laneId].phase
       and (active.phase == "TRANSFERRING" or active.phase == "ALLOCATING") then
      sched:defer(step, "transfer-" .. laneId .. "-" .. (active._transferStep or "?"))
    end
  end

  sched:defer(step, "transfer-" .. laneId .. "-start")
  active._transferDeferred = true
  return true
end

-- =========================================================================
-- Transfer sub-pipeline: store → stock → wait → pull → verify → clear
-- =========================================================================

function TransferringPhase:_transferForJob(addr, active, phases)
  local manifest = active.manifest

  if manifest.status == "ALLOCATING" then
    manifest:updateState("TRANSFERRING")
    if self._logger then
      self._logger:info("TRANSFERRING FOR JOB: " .. manifest.id ..
        " UPDATED TO TRANSFERRING")
    end
  end

  if active._transferStep == nil then
    active._transferStep  = "store"
    active._transferTick  = 0
    active._transferDbSlots = { items = {}, fluids = {} }
  end
  active._transferStartedAt = active._transferStartedAt or now()

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
    active.phase = phases.CLEANUP or "CLEANUP"
    return
  end

  local ifaceAddr = laneCfg.dualInterface
  if not ifaceAddr or ifaceAddr == "" then
    manifest:fault("No Dual Interface for lane " .. laneId)
    active.phase = phases.CLEANUP or "CLEANUP"
    return
  end

  local transposerAddr = laneCfg.transposerAddr
  local ifaceSide  = laneCfg.pull
  local inputSide  = laneCfg.push
  local returnSide = laneCfg.return_

  if ifaceSide == nil or inputSide == nil then
    manifest:fault("Cannot resolve transfer sides for lane " .. laneId)
    active.phase = phases.CLEANUP or "CLEANUP"
    return
  end

  local dbAddr = self._databaseAddr
  local hal    = self._hal
  local inputs = manifest.inputs

  active._transferTick = active._transferTick + 1
  local TICK   = active._transferTick
  local STEP   = active._transferStep
  local DBSLOTS = active._transferDbSlots

  -- STEP: store
  if STEP == "store" then
    -- Preflight: validate slot budget before touching Database
    if not active._preflightDone then
      local itemsNeeded  = inputs.items and #inputs.items or 0
      local fluidsNeeded = inputs.fluids and #inputs.fluids or 0
      local maxSides = self._maxFluidSides or 6
      if fluidsNeeded > maxSides then
        manifest:fault("Lane " .. laneId .. " requires " .. fluidsNeeded ..
          " fluids but Dual Interface supports max " .. maxSides .. " fluid sides")
        active.phase = phases.CLEANUP or "CLEANUP"
        return
      end
      if (itemsNeeded + fluidsNeeded) > self._dbSlots then
        manifest:fault("Lane " .. laneId .. " requires " .. (itemsNeeded + fluidsNeeded) ..
          " item/fluid refs but Database only has " .. self._dbSlots .. " slots")
        active.phase = phases.CLEANUP or "CLEANUP"
        return
      end
      active._preflightDone = true
    end

    if dbAddr and dbAddr ~= "" then
      local meAddr = self._meControllerAddr
      local dbSlot = 1

      if inputs.items then
        for _, item in ipairs(inputs.items) do
          if dbSlot > self._dbSlots then break end
          local filter = { name = item.name or "unknown", damage = item.damage or 0 }
          local ok, err = hal:storeNetworkEntry(meAddr, filter, dbAddr, dbSlot)
          if ok then
            table.insert(DBSLOTS.items, {
              dbSlot = dbSlot, fluidDrop = nil,
              name = item.name, label = item.label or item.name or "unknown" })
            dbSlot = dbSlot + 1
          else
            manifest:fault("Failed to store item in Database for lane " .. laneId)
            active.phase = phases.CLEANUP or "CLEANUP"
            return
          end
        end
      end

      if inputs.fluids then
        for _, fluid in ipairs(inputs.fluids) do
          if dbSlot > self._dbSlots then break end
          local fluidLabel = fluid.label or fluid.name or "unknown"
          local filter = { label = "drop of " .. fluidLabel }
          local ok, err = hal:storeNetworkEntry(meAddr, filter, dbAddr, dbSlot)
          if ok then
            table.insert(DBSLOTS.items, {
              dbSlot = dbSlot, fluidDrop = true,
              name = fluid.name, label = fluidLabel })
            dbSlot = dbSlot + 1
          else
            manifest:fault("Failed to store fluid in Database for lane " .. laneId)
            active.phase = phases.CLEANUP or "CLEANUP"
            return
          end
        end
      end
    end
    active._transferStep = "stock"
  end

  -- STEP: stock
  if active._transferStep == "stock" then
    local fluidCount = 1
    for _, slot in ipairs(DBSLOTS.items) do
      if slot.fluidDrop then
        if fluidCount > 6 then break end
        local ok, err = hal:configureFluidExport(ifaceAddr, fluidCount, dbAddr, slot.dbSlot)
        slot.fluidSide = fluidCount
        if not ok then
          manifest:fault("Fluid config failed: " .. tostring(err))
          active.phase = phases.CLEANUP or "CLEANUP"
          return
        end
        fluidCount = fluidCount + 1
      else
        local ok = hal:configureInterfaceStocking(ifaceAddr, slot.dbSlot, dbAddr, slot.dbSlot, 64)
        if not ok then
          manifest:fault("Stock config failed")
          active.phase = phases.CLEANUP or "CLEANUP"
          return
        end
      end
    end
    active._transferStep = "pull"
    return
  end

  -- STEP: pull
  if active._transferStep == "pull" then
    if DBSLOTS.items and #DBSLOTS.items > 0 then
      -- Always drain once before checking contents
      if not active._drainCalled then
        local moved = hal:drainInventory(transposerAddr, ifaceSide, inputSide)
        active._drainCalled = true
        if moved and moved > 0 then
          active._lastMoved = moved
          active._transferAttempts = nil
        else
          active._transferAttempts = (active._transferAttempts or 0) + 1
          if active._transferAttempts >= 3 then
            manifest:fault(string.format(
              "TRANSFER: lane %s moved zero items after %d attempts",
              laneId, active._transferAttempts))
            active.phase = phases.CLEANUP or "CLEANUP"
            return
          end
        end
        return
      end
      -- Already drained — check if anything remains
      local meAddr = self._meControllerAddr
      if meAddr and meAddr ~= "" then
        local contents = hal:getMEContents(meAddr)
        if contents and #contents.items == 0 and #contents.fluids == 0 then
          active._transferStep = "clear"
          return
        end
        -- Items or fluids still in network — reconfigure, then drain
        if contents and (#contents.items > 0 or #contents.fluids > 0) then
          for _, slot in ipairs(DBSLOTS.items) do
            if slot.fluidDrop then
              -- Reconfigure fluid export if this fluid is still in network
              local found = false
              for _, f in ipairs(contents.fluids) do
                if f.name == slot.name or f.label == slot.label then found = true; break end
              end
              if found then
                hal:configureFluidExport(ifaceAddr, slot.fluidSide or 1, dbAddr, slot.dbSlot)
              end
            else
              -- Reconfigure item stocking if this item is still in network
              local found = false
              for _, item in ipairs(contents.items) do
                if item.name == slot.name then found = true; break end
              end
              if found then
                hal:configureInterfaceStocking(ifaceAddr, slot.dbSlot, dbAddr, slot.dbSlot, 64)
              end
            end
          end
          -- Drain after reconfigure
          if #contents.items > 0 then
            local moved = hal:drainInventory(transposerAddr, ifaceSide, inputSide)
            if moved and moved > 0 then
              active._lastMoved = moved
              active._transferAttempts = nil
            else
              active._transferAttempts = (active._transferAttempts or 0) + 1
              if active._transferAttempts >= 3 then
                manifest:fault(string.format(
                  "TRANSFER: lane %s moved zero items after %d attempts",
                  laneId, active._transferAttempts))
                active.phase = phases.CLEANUP or "CLEANUP"
                return
              end
            end
          end
          return
        end
      end
    end
    active._transferStep = "verify"
    return
  end

  -- STEP: verify
  if active._transferStep == "verify" then
    active._lastMoved = nil
    active._transferStep = "clear"
    return
  end

  -- STEP: clear
  if active._transferStep == "clear" then
    for _, slot in ipairs(DBSLOTS.items) do
      if slot.fluidDrop then
        hal:clearFluidExport(ifaceAddr, slot.fluidSide or 0)
      else
        hal:clearInterfaceSlot(ifaceAddr, slot.dbSlot)
      end
    end
    if dbAddr and dbAddr ~= "" then
      for _, slot in ipairs(DBSLOTS.items) do
        hal:clearDatabaseSlot(dbAddr, slot.dbSlot)
      end
    end

    if self._redstoneLockAddr and self._redstoneLockAddr ~= "" then
      self._hal:pulseRedstoneLock(self._redstoneLockAddr, self._redstoneLockSide, 0.1)
    end

    manifest:updateState("PROCESSING")
    active.phase = phases.PROCESSING or "PROCESSING"
    -- Transfer state is done — clean up so nothing re-queues
    active._transferStep = nil
    active._transferDeferred = nil
    if self._logger then
      self._logger:info(string.format(
        "TRANSFER: lane %s complete — iface+DB cleared, → PROCESSING", laneId))
    end
  end
end

return TransferringPhase
