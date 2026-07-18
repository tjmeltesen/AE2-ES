-- MachineNode.lua
-- AE2-ES Module A2: MachineNode
-- Pure software abstraction of a physical GT machine.
-- Provides status tracking, exclusive locking, fault management.
-- Hardware I/O is owned by HAL (hal.lua) — MachineNode only stores state.
--
-- Status lifecycle:
--   AVAILABLE  → LOCKED      (lock for exclusive dispatch)
--   LOCKED     → PROCESSING  (JobManifest bound, machine active)
--   PROCESSING → AVAILABLE   (job completed normally)
--   * → FAULTED              (hardware error detected)
--   FAULTED    → AVAILABLE   (maintenance resolved)
--
-- Dependencies: none (standard Lua libraries only)

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
-- Supports two calling conventions:
--   1. Legacy (1 positional arg): (hardwareAddress)
--   2. New (2 args with options table): (hardwareAddress, optionsTable)
--      optionsTable fields: hardwareAddress, machineType, laneId
-- @param hardwareAddress  string  Component address of the GT machine (via adapter)
-- @param arg2             string|table  machineType (legacy) or options table (new)
-- @return MachineNode instance
function MachineNode.new(hardwareAddress, arg2)
  assert(type(hardwareAddress) == "string" and #hardwareAddress > 0,
         "hardwareAddress is required")

  local machineType, laneId

  if type(arg2) == "table" then
    -- New convention: options table
    machineType = arg2.machineType or "gt_machine"
    laneId      = arg2.laneId
  elseif type(arg2) == "string" then
    -- Legacy convention: positional machineType
    machineType = arg2
  else
    machineType = "gt_machine"
  end

  local self = setmetatable({
    hardwareAddress  = hardwareAddress,
    machineType      = machineType,
    laneId           = laneId,
    status           = MachineNode.STATUS.AVAILABLE,
    activeJob        = nil,    -- JobManifest reference when PROCESSING
    maintenanceFlags = {
      hasFault    = false,
      code        = 0,
      description = "",
      timestamp   = 0,
    },
    _pollInterval    = DEFAULT_POLL_INTERVAL,
    _cachedProgress  = 0,
    _lastPollTime    = 0,
  }, MachineNode)

  if type(arg2) == "table" and arg2.useStateMachine == true then
    local StateMachine = require("lib.state_machine")
    self._stateMachine = StateMachine.new(self.status, self)
    for _, status in pairs(MachineNode.STATUS) do
      self._stateMachine:addState(status, {
        enter = function(node)
          node.status = status
        end,
      })
    end
  end

  return self
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
  if self._stateMachine then
    self._stateMachine:transition(newStatus)
  else
    self.status = newStatus
  end
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
  self:setStatus(MachineNode.STATUS.LOCKED)
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
  self:setStatus(MachineNode.STATUS.AVAILABLE)
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
  self:setStatus(MachineNode.STATUS.PROCESSING)
  self.activeJob = job
  return true
end

--- Release the completed job and return to AVAILABLE.
-- @return boolean  true if transition succeeded
function MachineNode:releaseJob()
  if self.status ~= MachineNode.STATUS.PROCESSING then
    return false
  end
  self:setStatus(MachineNode.STATUS.AVAILABLE)
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
  self:setStatus(MachineNode.STATUS.FAULTED)
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
  self:setStatus(MachineNode.STATUS.AVAILABLE)
  self.activeJob = nil
  return true
end

------------------------------------------------------------------------
-- Hardware state (updated by HAL)
------------------------------------------------------------------------

--- Update cached hardware state after a HAL poll.
-- Called by HAL:pollMachineHardware() — MachineNode does NOT reach out to hardware.
-- @param progress  number  Current work progress from GT machine
function MachineNode:updateHardwareState(progress)
  self._cachedProgress = progress or 0
  self._lastPollTime   = os.time()
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
  self:setStatus(MachineNode.STATUS.AVAILABLE)
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
