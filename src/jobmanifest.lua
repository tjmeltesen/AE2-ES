-- Canonical JobManifest domain module. Safe to import outside OpenComputers.
--
-- Windows resolves ./src/JobManifest.lua to this file before the root
-- compatibility shim. Return the canonical cached module for that spelling.
local moduleName = ...
if moduleName == "JobManifest" then
  return require("src.jobmanifest")
end

local JobManifest = {}
JobManifest.__index = JobManifest

-- Valid state transitions
local STATE = {
  BUFFERING  = "BUFFERING",
  LOGGING    = "LOGGING",
  ALLOCATING = "ALLOCATING",
  TRANSFERRING = "TRANSFERRING",
  PROCESSING = "PROCESSING",
  CLEANUP    = "CLEANUP",
  COMPLETE   = "COMPLETE",
  COMPLETED  = "COMPLETED",
  FAULTED    = "FAULTED",
  PENDING    = "PENDING",
  DISPATCHED = "DISPATCHED",
}

JobManifest.STATE = STATE

local VALID_TRANSITIONS = {
  BUFFERING = { LOGGING = true, FAULTED = true },
  LOGGING = { ALLOCATING = true, FAULTED = true },
  ALLOCATING = { TRANSFERRING = true, FAULTED = true },
  TRANSFERRING = { PROCESSING = true, FAULTED = true },
  PROCESSING = { CLEANUP = true, FAULTED = true },
  CLEANUP = { COMPLETE = true, COMPLETED = true, FAULTED = true },
  PENDING = { DISPATCHED = true, ALLOCATING = true, FAULTED = true },
  DISPATCHED = { ALLOCATING = true, FAULTED = true },
  COMPLETE = {},
  COMPLETED = {},
  FAULTED = {},
}

local TERMINAL_STATES = { COMPLETE = true, COMPLETED = true, FAULTED = true }
local STATE_STALE_TIMEOUTS = {
  BUFFERING = 120, LOGGING = 60, ALLOCATING = 300, TRANSFERRING = 600,
  PROCESSING = 3600, CLEANUP = 120,
}

local function timestamp()
  return os.epoch and os.epoch() or os.time()
end

--- JIT-generated tables that MUST be nilled on cleanup.
--- These simulate the runtime structures built dynamically.
local function createJITTables()
  return {
    inputRegistry = {},    -- maps item type → quantity required
    hardwareBinds = {},    -- maps machine index → MachineNode
    transferPlan = {},     -- ordered list of transfer operations
    processingLog = {},    -- per-machine processing records
    errorLog = {},         -- fault records during execution
  }
end

--- Create a new JobManifest
--- @param jobId string unique identifier
--- @param inputs table mapping item keys → quantities
--- @return JobManifest
function JobManifest.new(jobId, inputs)
  assert(jobId ~= nil, "JobManifest requires a jobId")
  local self = setmetatable({}, JobManifest)
  self.jobId = jobId
  self.id = jobId
  self.state = STATE.BUFFERING
  self.status = STATE.BUFFERING
  self.createdAt = timestamp()
  self.updatedAt = self.createdAt
  self.inputs = inputs or {}
  self.assignedMachine = nil
  self.completedAt = nil
  self.faultReason = nil
  self.metadata = {}

  -- JIT-allocated runtime tables
  local jit = createJITTables()
  self._inputRegistry = jit.inputRegistry
  self._hardwareBinds = jit.hardwareBinds
  self._transferPlan = jit.transferPlan
  self._processingLog = jit.processingLog
  self._errorLog = jit.errorLog

  return self
end

--- Bind a machine to this job for processing
--- @param machineIndex number or string (address when single-arg)
--- @param machineNode table MachineNode abstraction (optional)
function JobManifest:bindHardware(machineIndex, machineNode)
  -- The indexed form is an internal diagnostic binding and may retain
  -- multiple machine nodes throughout the job lifecycle. The public
  -- single-address form retains the production ALLOCATING/single-bind
  -- contract below.
  if machineNode ~= nil then
    self._hardwareBinds[machineIndex] = machineNode
    return true
  end
  if self.status ~= STATE.ALLOCATING then return false end
  if self.assignedMachine ~= nil then return false end
  if machineNode == nil and type(machineIndex) == "string" then
    machineNode = { address = machineIndex }
  end
  self._hardwareBinds[machineIndex] = machineNode
  self.assignedMachine = type(machineIndex) == "string"
    and machineIndex or (machineNode and machineNode.address)
  self.updatedAt = timestamp()
  return true
end

--- Transition to the next state
--- @param newState string one of STATE.*
--- @return boolean success
function JobManifest:updateState(newState)
  if self:isTerminal() then return false end
  if self._allowDirectStateTransitions and STATE[newState] then
    self.state = newState
    self.status = newState
    self.updatedAt = timestamp()
    if newState == STATE.COMPLETED then self.completedAt = self.updatedAt end
    return true
  end
  if not VALID_TRANSITIONS[self.status] or not VALID_TRANSITIONS[self.status][newState] then
    return false
  end
  self.state = newState
  self.status = newState
  self.updatedAt = timestamp()
  if newState == STATE.COMPLETED then self.completedAt = self.updatedAt end
  return true
end

function JobManifest:isTerminal()
  return TERMINAL_STATES[self.status] == true
end

--- Check if this job has exceeded its TTL
--- @return boolean
function JobManifest:isStale(now)
  now = now or timestamp()
  -- COMPLETE is the JIT cleanup sentinel and is eligible for removal. The
  -- production terminal states retain their records for diagnostics.
  if self.state == STATE.COMPLETE then return true end
  if self.status == STATE.COMPLETED or self.status == STATE.FAULTED then return false end
  local timeout = STATE_STALE_TIMEOUTS[self.status] or 300
  return now - (self.updatedAt or self.createdAt) > timeout
end

function JobManifest:setStaleTimeout(seconds)
  assert(type(seconds) == "number" and seconds > 0, "stale timeout must be a positive number")
  STATE_STALE_TIMEOUTS[self.status] = seconds
end

--- Log a processing event for a machine
--- @param machineIndex number
--- @param event table {type, timestamp, detail}
function JobManifest:logProcessing(machineIndex, event)
  if not self._processingLog[machineIndex] then
    self._processingLog[machineIndex] = {}
  end
  table.insert(self._processingLog[machineIndex], event)
end

--- Log an error/fault
--- @param error table {code, machine, message, timestamp}
function JobManifest:logError(error)
  table.insert(self._errorLog, error)
end

--- Add a transfer operation to the plan
--- @param op table {from, to, item, count}
function JobManifest:addTransfer(op)
  table.insert(self._transferPlan, op)
end

--- Register an input requirement
--- @param itemKey string
--- @param quantity number
function JobManifest:registerInput(itemKey, quantity)
  self._inputRegistry[itemKey] = (self._inputRegistry[itemKey] or 0) + quantity
end

--- Get all JIT table references (for testing cleanup)
--- @return table of table references
function JobManifest:getJITTables()
  return {
    _inputRegistry = self._inputRegistry,
    _hardwareBinds = self._hardwareBinds,
    _transferPlan = self._transferPlan,
    _processingLog = self._processingLog,
    _errorLog = self._errorLog,
  }
end

--- Complete the job and nil out all JIT-allocated tables.
--- This is the CRITICAL cleanup path — failure to nil these
--- tables causes memory leaks across job cycles.
function JobManifest:complete()
  self.state = STATE.COMPLETE
  self.status = STATE.COMPLETE
  self.updatedAt = timestamp()
  self.completedAt = self.updatedAt

  -- Nil out ALL JIT-allocated tables to free memory
  -- These MUST be nilled, not just emptied
  self._inputRegistry = nil
  self._hardwareBinds = nil
  self._transferPlan = nil
  self._processingLog = nil
  self._errorLog = nil
end

--- Mark the job as faulted without cleanup
--- Check if JIT tables have been properly cleaned up
--- @return boolean true if all JIT tables are nil
function JobManifest:isJITCleaned()
  return self._inputRegistry == nil
     and self._hardwareBinds == nil
     and self._transferPlan == nil
     and self._processingLog == nil
     and self._errorLog == nil
end

--- Get the age of this job in seconds
--- @return number seconds since creation
function JobManifest:age()
  local now = self.completedAt or timestamp()
  return (now - self.createdAt) / (os.epoch and 1000 or 1)
end

--- Unbind all hardware from this job
function JobManifest:unbindHardware()
  if not self.assignedMachine then return false end
  self._hardwareBinds = {}
  self.assignedMachine = nil
  self.updatedAt = timestamp()
  return true
end

--- Fault this job with a reason
--- @param reason string description of the fault (optional)
function JobManifest:fault(reason)
  if self:isTerminal() then return false end
  self.state = STATE.FAULTED
  self.status = STATE.FAULTED
  self.faultReason = reason or "Unknown fault"
  self.updatedAt = timestamp()
  -- Preserve an already-recorded root cause, but ensure callers that only
  -- fault the manifest still leave a diagnostic for maintenance reporting.
  if #self._errorLog == 0 then
    self:logError({
      code = "FAULT", message = self.faultReason, timestamp = self.updatedAt,
    })
  end
  return true
end

function JobManifest:setMeta(key, value)
  self.metadata[key] = value
  self.updatedAt = timestamp()
end

function JobManifest:getMeta(key)
  return self.metadata[key]
end

function JobManifest:summarize()
  return {
    id = self.id, status = self.status, assignedMachine = self.assignedMachine,
    inputs = self.inputs, createdAt = self.createdAt, updatedAt = self.updatedAt,
    completedAt = self.completedAt, faultReason = self.faultReason,
    age = self:age(), isStale = self:isStale(), isTerminal = self:isTerminal(),
  }
end

return JobManifest
