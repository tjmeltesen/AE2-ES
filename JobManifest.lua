-- JobManifest.lua
-- AE2-ES Module A1: JobManifest
-- Atomic unit of work — generated JIT when central buffer stabilizes.
-- Tracks inputs, binds to hardware, manages 6-phase state transitions.
-- Purged after CLEANUP completes.
--
-- State machine:
--   BUFFERING  → LOGGING → ALLOCATING → TRANSFERRING → PROCESSING → CLEANUP
--   Any state can transition to FAULTED on error.
--
-- Dependencies: none (standard Lua libraries only)
-- OC constraints: all methods yield via table operations (no long loops)

local JobManifest = {}
JobManifest.__index = JobManifest

-- Valid state transitions
local VALID_TRANSITIONS = {
  BUFFERING    = { LOGGING = true, FAULTED = true },
  LOGGING      = { ALLOCATING = true, FAULTED = true },
  ALLOCATING   = { TRANSFERRING = true, FAULTED = true },
  TRANSFERRING = { PROCESSING = true, FAULTED = true },
  PROCESSING   = { CLEANUP = true, FAULTED = true },
  CLEANUP      = { COMPLETED = true, FAULTED = true },
  COMPLETED    = {},
  FAULTED      = {},
}

-- Terminal states that cannot transition further
local TERMINAL_STATES = { COMPLETED = true, FAULTED = true }

-- Default stale timeout per state (seconds)
local STATE_STALE_TIMEOUTS = {
  BUFFERING    = 120,
  LOGGING      = 60,
  ALLOCATING   = 300,
  TRANSFERRING = 600,
  PROCESSING   = 3600,
  CLEANUP      = 120,
}

--- Create a new JobManifest instance.
-- @param jobId  string  unique identifier for this job (required)
-- @param inputs table   input specification (item/fluid requirements)
-- @return JobManifest instance
function JobManifest.new(jobId, inputs)
  assert(jobId ~= nil, "JobManifest requires a jobId")

  return setmetatable({
    id              = jobId,
    status          = "BUFFERING",       -- initial state
    inputs          = inputs or {},       -- table of { type, id, amount, ... }
    assignedMachine = nil,                -- MachineNode address when bound
    createdAt       = os.time(),
    updatedAt       = os.time(),
    completedAt     = nil,                -- set on COMPLETED
    faultReason     = nil,                -- set on FAULTED
    metadata        = {},                 -- extensible metadata table
  }, JobManifest)
end

------------------------------------------------------------------------
-- State management
------------------------------------------------------------------------

--- Transition to a new state with validation.
-- Validates that the transition is legal per the state machine.
-- @param newStatus  string  target state
-- @return boolean   true if transition succeeded, false if invalid
function JobManifest:updateState(newStatus)
  if self:isTerminal() then
    return false  -- terminal states are locked
  end

  local allowed = VALID_TRANSITIONS[self.status]
  if not allowed or not allowed[newStatus] then
    return false  -- illegal transition
  end

  self.status    = newStatus
  self.updatedAt = os.time()

  if newStatus == "COMPLETED" then
    self.completedAt = os.time()
  end

  return true
end

--- Check if the manifest is in a terminal state.
-- @return boolean
function JobManifest:isTerminal()
  return TERMINAL_STATES[self.status] == true
end

--- Mark the job as faulted with a reason.
-- Can be called from any non-terminal state.
-- @param reason  string  description of the fault
-- @return boolean
function JobManifest:fault(reason)
  if self:isTerminal() then
    return false
  end

  self.status     = "FAULTED"
  self.faultReason = reason or "Unknown fault"
  self.updatedAt  = os.time()
  return true
end

------------------------------------------------------------------------
-- Hardware binding
------------------------------------------------------------------------

--- Bind this manifest to a specific machine node.
-- Only valid during ALLOCATING state.
-- @param machineAddr  string  MachineNode address
-- @return boolean     true if bound successfully
function JobManifest:bindHardware(machineAddr)
  if self.status ~= "ALLOCATING" then
    return false
  end

  if self.assignedMachine ~= nil then
    return false
  end

  self.assignedMachine = machineAddr
  self.updatedAt       = os.time()
  return true
end

--- Unbind from the currently assigned machine.
-- Resets assignedMachine to nil.
-- @return boolean  true if unbound, false if nothing to unbind
function JobManifest:unbindHardware()
  if not self.assignedMachine then
    return false
  end

  self.assignedMachine = nil
  self.updatedAt       = os.time()
  return true
end

------------------------------------------------------------------------
-- Stale detection
------------------------------------------------------------------------

--- Check if this manifest is stale (exceeded expected duration).
-- Each state has its own timeout threshold.
-- Terminal states are never stale.
-- @param now  optional timestamp (default: os.time())
-- @return boolean
function JobManifest:isStale(now)
  now = now or os.time()

  -- Terminal states are never stale
  if self:isTerminal() then
    return false
  end

  local timeout = STATE_STALE_TIMEOUTS[self.status] or 300
  local age     = now - (self.updatedAt or self.createdAt)

  return age > timeout
end

--- Override the stale timeout for the current state.
-- @param seconds  number  new timeout in seconds
function JobManifest:setStaleTimeout(seconds)
  assert(type(seconds) == "number" and seconds > 0,
         "stale timeout must be a positive number")
  STATE_STALE_TIMEOUTS[self.status] = seconds
end

------------------------------------------------------------------------
-- Inspection / metadata
------------------------------------------------------------------------

--- Get total job lifetime so far.
-- @return number  seconds since creation
function JobManifest:age()
  local endTime = self.completedAt or os.time()
  return endTime - self.createdAt
end

--- Set arbitrary metadata on this manifest.
-- @param key    string
-- @param value  any
function JobManifest:setMeta(key, value)
  self.metadata[key] = value
  self.updatedAt = os.time()
end

--- Get metadata value.
-- @param key  string
-- @return any
function JobManifest:getMeta(key)
  return self.metadata[key]
end

--- Return a read-only summary of the manifest state.
-- @return table  summary fields
function JobManifest:summarize()
  return {
    id              = self.id,
    status          = self.status,
    assignedMachine = self.assignedMachine,
    inputs          = self.inputs,
    createdAt       = self.createdAt,
    updatedAt       = self.updatedAt,
    completedAt     = self.completedAt,
    faultReason     = self.faultReason,
    age             = self:age(),
    isStale         = self:isStale(),
    isTerminal      = self:isTerminal(),
  }
end

return JobManifest
