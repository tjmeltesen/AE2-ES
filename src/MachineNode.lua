-- MachineNode.lua
-- AE2-ES Module A2: MachineNode
-- Software abstraction of a physical GT machine coupled with an AE2 ME Interface.
-- Provides status tracking, hardware polling, exclusive locking, and ghost-item cleanup.
--
-- Expected coupled components (loose coupling — only hardwareAddress is required):
--   - GT machine component (via adapter or MFU) for status/progress queries
--   - ME Interface component for pattern configuration and ghost-item flushing
--
-- Status lifecycle:
--   AVAILABLE  → LOCKED      (lock for exclusive dispatch)
--   LOCKED     → PROCESSING  (JobManifest bound, machine active)
--   PROCESSING → AVAILABLE   (job completed normally)
--   * → FAULTED              (hardware error detected)
--   FAULTED    → AVAILABLE   (maintenance resolved)
--
-- Dependencies: none (standard Lua libraries only)
-- OC constraints: pollHardware may call component proxied methods; callers must yield

local MachineNode = {}
MachineNode.__index = MachineNode

-- Status constants
MachineNode.STATUS = {
  AVAILABLE  = "AVAILABLE",
  LOCKED     = "LOCKED",
  PROCESSING = "PROCESSING",
  FAULTED    = "FAULTED",
}

-- Default maintenance poll interval (seconds)
local DEFAULT_POLL_INTERVAL = 5

--- Create a new MachineNode instance.
-- @param hardwareAddress   string  Component address of the GT machine
-- @param interfaceAddress  string  Component address of the ME Interface
-- @param machineType       string  Human-readable machine type (e.g. "gt_machine")
-- @return MachineNode instance
function MachineNode.new(hardwareAddress, interfaceAddress, machineType)
  assert(type(hardwareAddress) == "string" and #hardwareAddress > 0,
         "hardwareAddress is required")
  return setmetatable({
    hardwareAddress    = hardwareAddress,
    interfaceAddress   = interfaceAddress or "",
    machineType        = machineType or "gt_machine",
    status             = MachineNode.STATUS.AVAILABLE,
    activeJob          = nil,    -- JobManifest reference when PROCESSING
    maintenanceFlags   = {
      hasFault        = false,
      code            = 0,
      description     = "",
      timestamp       = 0,
    },
    _pollInterval      = DEFAULT_POLL_INTERVAL,
    _cachedProgress    = 0,
    _lastPollTime      = 0,
  }, MachineNode)
end

------------------------------------------------------------------------
-- Status accessors
------------------------------------------------------------------------

--- Get the current status string.
-- @return string
function MachineNode:getStatus()
  return self.status
end

--- Set the status directly (internal use; prefer lock/unlock/reportFault).
-- @param newStatus  string  One of MachineNode.STATUS.*
function MachineNode:setStatus(newStatus)
  self.status = newStatus
end

--- Check if the machine is available for dispatching.
-- @return boolean
function MachineNode:isAvailable()
  return self.status == MachineNode.STATUS.AVAILABLE
end

--- Check if the machine is in FAULTED status.
-- @return boolean
function MachineNode:isFaulted()
  return self.status == MachineNode.STATUS.FAULTED
end

--- Check if the machine has an active maintenance fault.
-- @return boolean
function MachineNode:hasFault()
  return self.maintenanceFlags.hasFault
end

--- Get the active job reference (if any).
-- @return table or nil
function MachineNode:getActiveJob()
  return self.activeJob
end

--- Get the machine's type name.
-- @return string
function MachineNode:getMachineType()
  return self.machineType
end

------------------------------------------------------------------------
-- Lock / unlock
------------------------------------------------------------------------

--- Lock the machine for exclusive dispatch.
-- Transitions AVAILABLE → LOCKED.
-- @return boolean  true if lock acquired
function MachineNode:lock()
  if self.status ~= MachineNode.STATUS.AVAILABLE then
    return false
  end
  self.status = MachineNode.STATUS.LOCKED
  return true
end

--- Unlock the machine (release from LOCKED state or recovery from FAULTED).
-- Transitions LOCKED|FAULTED → AVAILABLE.
-- Will not unlock a PROCESSING machine (must complete or fault first).
-- @return boolean  true if unlock succeeded
function MachineNode:unlock()
  if self.status == MachineNode.STATUS.PROCESSING then
    return false
  end
  self.status = MachineNode.STATUS.AVAILABLE
  self.activeJob = nil
  return true
end

--- Transition LOCKED → PROCESSING after a job is bound.
-- @param job  JobManifest table to associate
-- @return boolean  true if transition succeeded
function MachineNode:bindJob(job)
  if self.status ~= MachineNode.STATUS.LOCKED then
    return false
  end
  if type(job) ~= "table" or not job.id then
    return false
  end
  self.status    = MachineNode.STATUS.PROCESSING
  self.activeJob = job
  return true
end

--- Release the completed job and return to AVAILABLE.
-- @return boolean  true if transition succeeded
function MachineNode:releaseJob()
  if self.status ~= MachineNode.STATUS.PROCESSING then
    return false
  end
  self.status    = MachineNode.STATUS.AVAILABLE
  self.activeJob = nil
  return true
end

------------------------------------------------------------------------
-- Fault management
------------------------------------------------------------------------

--- Record a maintenance fault on this machine.
-- Transitions any state → FAULTED.
-- @param code         number  Fault code
-- @param description  string  Human-readable fault description
function MachineNode:recordFault(code, description)
  self.status = MachineNode.STATUS.FAULTED
  self.maintenanceFlags = {
    hasFault    = true,
    code        = code or 0,
    description = description or "Unknown fault",
    timestamp   = os.time(),
  }
end

--- Inject a fault for testing purposes (alias for recordFault).
-- Matches the mock interface used by integration tests.
-- @param code         number  Fault code
-- @param description  string  Fault description
function MachineNode:injectFault(code, description)
  self:recordFault(code, description)
end

--- Clear the current fault and return to AVAILABLE.
-- @return boolean  true if fault was cleared
function MachineNode:clearFault()
  if not self.maintenanceFlags.hasFault then
    return false
  end
  self.maintenanceFlags = {
    hasFault    = false,
    code        = 0,
    description = "",
    timestamp   = 0,
  }
  self.status   = MachineNode.STATUS.AVAILABLE
  self.activeJob = nil
  return true
end

------------------------------------------------------------------------
-- Hardware polling
------------------------------------------------------------------------

--- Poll the physical machine hardware for current status.
-- Uses component.proxy(hardwareAddress) to query the GT machine.
-- Updates cachedProgress and detects faults.
-- NOTE: In a real OC environment this calls OC component APIs.
--       In test/emulated environments, provide a mock proxy via setProxy().
--
-- Returns the current (possibly updated) status string.
-- @return string  status after poll
function MachineNode:pollHardware()
  -- Attempt to query hardware via proxy
  local machine = self:_getProxy()
  if not machine then
    -- No proxy available (test environment or offline) — return current status
    return self.status
  end

  -- Check if the machine component is responsive
  local ok, err = pcall(function()
    return machine.isMachineActive and machine.getWorkProgress
  end)
  if not ok then
    self:recordFault(100, "Hardware proxy unresponsive: " .. tostring(err))
    return self.status
  end

  -- Read hardware state
  local active, progress, hasWork, workAllowed

  pcall(function()
    active      = machine.isMachineActive and machine.isMachineActive()
    progress    = machine.getWorkProgress and machine.getWorkProgress()
    hasWork     = machine.hasWork and machine.hasWork()
    workAllowed = machine.isWorkAllowed and machine.isWorkAllowed()
  end)

  -- Store cached progress regardless
  self._cachedProgress = progress or 0
  self._lastPollTime   = os.time()

  -- Fault detection: machine was PROCESSING but now inactive with unfinished work
  if self.status == MachineNode.STATUS.PROCESSING then
    if active == false and hasWork then
      self:recordFault(200, "Machine went inactive with work remaining")
    elseif active == false and progress and progress > 0 then
      self:recordFault(201, "Machine stalled mid-operation")
    end
  end

  return self.status
end

--- Set a custom proxy function for testing.
-- @param proxyFn  function or table  Callable proxy for hardware interaction
function MachineNode:setProxy(proxyFn)
  self._proxy = proxyFn
end

--- Get the hardware proxy (real or mock).
-- @return table or nil
function MachineNode:_getProxy()
  if self._proxy then
    return self._proxy
  end
  -- In a real OC environment, resolve via component.proxy
  local ok, proxy = pcall(require, "component")
  if ok and proxy and proxy.proxy then
    return proxy.proxy(self.hardwareAddress)
  end
  return nil
end

------------------------------------------------------------------------
-- Interface flush (ghost-item cleanup)
------------------------------------------------------------------------

--- Flush the ME Interface: clear all configured stocking slots.
-- This handles the ghost-items edge case where unconsumed inputs
-- remain in the interface after a job completes.
-- Uses the interfaceAddress if available.
-- @return boolean  true if flush was attempted (not necessarily successful)
function MachineNode:flushInterface()
  if not self.interfaceAddress or self.interfaceAddress == "" then
    -- No interface configured; nothing to flush
    return false
  end

  local iface = self:_getInterfaceProxy()
  if not iface then
    return false
  end

  -- Clear all 9 interface configuration slots (standard ME Interface)
  local cleared = 0
  for slot = 1, 9 do
    local ok = pcall(function()
      iface.setInterfaceConfiguration(slot)
    end)
    if ok then
      cleared = cleared + 1
    end
  end

  return cleared > 0
end

--- Get the ME Interface proxy (real or mock).
-- @return table or nil
function MachineNode:_getInterfaceProxy()
  if self._ifaceProxy then
    return self._ifaceProxy
  end
  local ok, proxy = pcall(require, "component")
  if ok and proxy and proxy.proxy then
    return proxy.proxy(self.interfaceAddress)
  end
  return nil
end

--- Set a custom interface proxy for testing.
-- @param proxyFn  function or table  Mock interface proxy
function MachineNode:setInterfaceProxy(proxyFn)
  self._ifaceProxy = proxyFn
end

------------------------------------------------------------------------
-- Telemetry snapshot
------------------------------------------------------------------------

--- Build a telemetry-ready summary of this machine node.
-- Used by TelemetryPayload (A7) for modem broadcasts.
-- @return table  Flat structure with machine state
function MachineNode:toTelemetry()
  return {
    hardwareAddress  = self.hardwareAddress,
    interfaceAddress = self.interfaceAddress,
    machineType      = self.machineType,
    status           = self.status,
    hasFault         = self.maintenanceFlags.hasFault,
    faultCode        = self.maintenanceFlags.code,
    faultDescription = self.maintenanceFlags.description,
    activeJobId      = self.activeJob and self.activeJob.id or nil,
    cachedProgress   = self._cachedProgress,
    lastPollTime     = self._lastPollTime,
  }
end

------------------------------------------------------------------------
-- Utility
------------------------------------------------------------------------

--- Return a human-readable maintenance report for this machine.
-- @return string
function MachineNode:toMaintenanceReport()
  if not self.maintenanceFlags.hasFault then
    return string.format("[%s] %s — OK",
      self.machineType, self.hardwareAddress:sub(1, 8))
  end
  return string.format("[%s] %s — FAULT %d: %s (since %s)",
      self.machineType,
      self.hardwareAddress:sub(1, 8),
      self.maintenanceFlags.code,
      self.maintenanceFlags.description,
      os.date("%c", self.maintenanceFlags.timestamp))
end

--- Reset the node to factory defaults (for testing / re-initialization).
function MachineNode:reset()
  self.status           = MachineNode.STATUS.AVAILABLE
  self.activeJob        = nil
  self.maintenanceFlags = {
    hasFault    = false,
    code        = 0,
    description = "",
    timestamp   = 0,
  }
  self._cachedProgress  = 0
  self._lastPollTime    = 0
end

return MachineNode
