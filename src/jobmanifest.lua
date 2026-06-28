-- JobManifest module
-- Atomic unit of work — generated JIT when central buffer stabilizes.
-- Tracks inputs, binds to hardware, manages state transitions.
-- Purged after cleanup (all JIT tables nilled).

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
  FAULTED    = "FAULTED",
}

JobManifest.STATE = STATE

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
  local self = setmetatable({}, JobManifest)
  self.jobId = jobId
  self.state = STATE.BUFFERING
  self.createdAt = os.epoch and os.epoch() or os.time()
  self.inputs = inputs or {}

  -- JIT-allocated runtime tables
  local jit = createJITTables()
  self._inputRegistry = jit.inputRegistry
  self._hardwareBinds = jit.hardwareBinds
  self._transferPlan = jit.transferPlan
  self._processingLog = jit.processingLog
  self._errorLog = jit.errorLog

  -- Field aliases for exec_broker compatibility
  self.id = jobId
  self.status = self.state
  self.updatedAt = self.createdAt

  return self
end

--- Bind a machine to this job for processing
--- @param machineIndex number or string (address when single-arg)
--- @param machineNode table MachineNode abstraction (optional)
function JobManifest:bindHardware(machineIndex, machineNode)
  if machineNode == nil and type(machineIndex) == 'string' then
    machineNode = { address = machineIndex }
  end
  self._hardwareBinds[machineIndex] = machineNode
end

--- Transition to the next state
--- @param newState string one of STATE.*
--- @return boolean success
function JobManifest:updateState(newState)
  if not STATE[newState] then return false end
  self.state = newState
  self.status = newState
  return true
end

--- Check if this job has exceeded its TTL
--- @return boolean
function JobManifest:isStale()
  if self.state == STATE.COMPLETE or self.state == STATE.FAULTED then
    return true
  end
  return false
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

  -- Nil out ALL JIT-allocated tables to free memory
  -- These MUST be nilled, not just emptied
  self._inputRegistry = nil
  self._hardwareBinds = nil
  self._transferPlan = nil
  self._processingLog = nil
  self._errorLog = nil
end

--- Mark the job as faulted without cleanup
function JobManifest:fault()
  self.state = STATE.FAULTED
end

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
  local now = os.epoch and os.epoch() or os.time()
  return (now - self.createdAt) / (os.epoch and 1000 or 1)
end

--- Unbind all hardware from this job
function JobManifest:unbindHardware()
  self._hardwareBinds = {}
end

--- Fault this job with a reason
--- @param reason string description of the fault (optional)
function JobManifest:fault(reason)
  self.state = STATE.FAULTED
  if reason then
    self.faultReason = reason
    self:logError({
      code = "FAULT",
      message = reason,
      timestamp = os.epoch and os.epoch() or os.time(),
    })
  end
end

return JobManifest
