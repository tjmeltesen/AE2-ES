--[[
MaintenanceReport.lua — MaintenanceReport (A6)
AE2 Execution System (AE2-ES)
Part of Deliverable A: Exec Broker, Module A6

Diagnostic component translating machine fault data into human-readable
descriptions for the Supervisor dashboard and local UI. Maintains an
append-only log of maintenance events for trend analysis and debugging.

Provides:
  - toHumanReadable(faultCode)    — fault code → player-readable string
  - logToHistory(event)           — persistent event log (auto-trim)
  - reportFault(code, desc)       — set current fault + log entry
  - clearFault(note)              — clear fault + log resolution
  - getHistory(limit)             — retrieve recent log entries
  - toTelemetry()                 — flat table for TelemetryPayload
  - toString()                    — multi-line textual report
  - Fields: machineId, faultCode, isRepairable

Dependencies: none (standard Lua + os.time/os.date)
Consumed by:  Exec Broker main loop (A8), TelemetryPayload (A7)
              Supervisor dashboard (B5), Local UI (A12)

Fault codes are shared constants matching HAL (A5) FAULT_* values:
  0 = NONE, 1 = POWER_STARVATION, 2 = ITEM_JAM, 3 = FLUID_ISSUE,
  4 = GHOST_ITEMS, 5 = NO_RECIPE, 6 = OVERFLOW, 7 = DISCONNECTED,
  8 = PROXY_ERROR
]]--

local MaintenanceReport = {}
MaintenanceReport.__index = MaintenanceReport

-- ===========================================================================
-- Severity levels
-- ===========================================================================
MaintenanceReport.SEVERITY = {
  INFO     = "INFO",
  WARNING  = "WARNING",
  CRITICAL = "CRITICAL",
}

-- ===========================================================================
-- Fault code registry — single source of truth for severity, message,
-- repairability, and repair guidance per code.
-- Indexed by fault code (0–8, matching HAL FAULT_* constants).
-- ===========================================================================
local FAULT_REGISTRY = setmetatable({}, {
  __index = function(_, code)
    -- Fallback for unrecognised fault codes
    return {
      severity     = MaintenanceReport.SEVERITY.WARNING,
      message      = "Unknown Fault #" .. tostring(code),
      isRepairable = false,
      guidance     = "Manual inspection required — fault code not in registry",
    }
  end,
})

-- 0: No fault
FAULT_REGISTRY[0] = {
  severity     = MaintenanceReport.SEVERITY.INFO,
  message      = "No Fault — machine operating normally",
  isRepairable = false,
  guidance     = "No action needed",
}

-- 1: Power Starvation
FAULT_REGISTRY[1] = {
  severity     = MaintenanceReport.SEVERITY.CRITICAL,
  message      = "Power Starvation — EU supply critically low or absent",
  isRepairable = true,
  guidance     = "Check EU supply line: verify cables, generators, and AE2 power budget",
}

-- 2: Item Jam
FAULT_REGISTRY[2] = {
  severity     = MaintenanceReport.SEVERITY.WARNING,
  message      = "Item Jam — machine has queued work but is not actively processing",
  isRepairable = true,
  guidance     = "Check output bus for blockages and ensure input items/fluids are stocked",
}

-- 3: Fluid Issue
FAULT_REGISTRY[3] = {
  severity     = MaintenanceReport.SEVERITY.WARNING,
  message      = "Fluid Issue — machine has work but fluid supply or output is blocked",
  isRepairable = true,
  guidance     = "Verify fluid input hatch supply and output hatch for full tanks",
}

-- 4: Ghost Items
FAULT_REGISTRY[4] = {
  severity     = MaintenanceReport.SEVERITY.WARNING,
  message      = "Ghost Items — stranded items detected in ME interface after job completion",
  isRepairable = true,
  guidance     = "Initiate interface flush to clear residual items; check transposer routing",
}

-- 5: No Recipe
FAULT_REGISTRY[5] = {
  severity     = MaintenanceReport.SEVERITY.WARNING,
  message      = "No Recipe — machine has no valid recipe configured for current inputs",
  isRepairable = true,
  guidance     = "Verify ME interface pattern configuration or check input item types",
}

-- 6: Overflow
FAULT_REGISTRY[6] = {
  severity     = MaintenanceReport.SEVERITY.CRITICAL,
  message      = "Overflow — machine output buffer is full, preventing job completion",
  isRepairable = true,
  guidance     = "Clear output bus or output hatch to free space for new products",
}

-- 7: Disconnected
FAULT_REGISTRY[7] = {
  severity     = MaintenanceReport.SEVERITY.CRITICAL,
  message      = "Disconnected — machine component is unreachable or offline",
  isRepairable = true,
  guidance     = "Verify adapter/MFU connection; check chunk loading and cable routing",
}

-- 8: Proxy Error
FAULT_REGISTRY[8] = {
  severity     = MaintenanceReport.SEVERITY.CRITICAL,
  message      = "Proxy Error — OC component proxy returned an error",
  isRepairable = false,
  guidance     = "Restart OC computer or re-connect component; check for mod conflicts",
}

-- 9: Needs Maintenance
FAULT_REGISTRY[9] = {
  severity     = MaintenanceReport.SEVERITY.WARNING,
  message      = "Needs Maintenance — maintenance hatch requires attention",
  isRepairable = true,
  guidance     = "Perform maintenance on machine with appropriate tools (screwdriver, hammer, etc.)",
}

-- 10: Has Problems
FAULT_REGISTRY[10] = {
  severity     = MaintenanceReport.SEVERITY.WARNING,
  message      = "Has Problems — machine reports unresolved problem state",
  isRepairable = true,
  guidance     = "Inspect machine GUI for specific problem details; resolve before resuming",
}

-- 11: Incomplete Structure
FAULT_REGISTRY[11] = {
  severity     = MaintenanceReport.SEVERITY.CRITICAL,
  message      = "Incomplete Structure — multiblock structure is missing required blocks",
  isRepairable = true,
  guidance     = "Verify all hatches, casings, and structural blocks are correctly placed",
}

-- Maximum entries in the history log before auto-trim
local DEFAULT_MAX_HISTORY = 100

-- ===========================================================================
-- Constructor
-- ===========================================================================

--- Create a new MaintenanceReport instance for a given machine.
-- @param machineId  string — identifier for the machine
--                   (hardware address or short name, e.g. "gt_machine_01")
-- @return MaintenanceReport instance
function MaintenanceReport.new(machineId)
  return setmetatable({
    -- Public fields
    machineId    = machineId or "unknown",
    faultCode    = 0,
    isRepairable = false,

    -- Internal state
    _history     = {},
    _maxHistory  = DEFAULT_MAX_HISTORY,
    _lastReport  = nil,
  }, MaintenanceReport)
end

-- ===========================================================================
-- Fault code translation
-- ===========================================================================

--- Translate a fault code to a human-readable string with severity prefix.
-- Fault code 0 returns just the message (no severity bracket).
-- Unknown fault codes return a descriptive fallback.
--
-- @param faultCode  number — one of the FAULT_* values (0–11)
-- @return string  e.g. "[CRITICAL] Power Starvation — EU supply critically low"
--                 or   "No Fault — machine operating normally"
function MaintenanceReport:toHumanReadable(faultCode)
  local entry = FAULT_REGISTRY[faultCode]
  if entry.severity == MaintenanceReport.SEVERITY.INFO then
    return entry.message
  end
  return string.format("[%s] %s", entry.severity, entry.message)
end

--- Get the severity level for a given fault code.
-- @param faultCode  number
-- @return string  SEVERITY.* value
function MaintenanceReport:getSeverity(faultCode)
  return FAULT_REGISTRY[faultCode].severity
end

--- Get repair guidance text for a given fault code.
-- @param faultCode  number
-- @return string  Human-readable guidance
function MaintenanceReport:getGuidance(faultCode)
  return FAULT_REGISTRY[faultCode].guidance
end

--- Check whether a fault code represents a repairable condition.
-- Repairable faults can be auto-resolved by the system (e.g. power restore,
-- item jam clear, ghost item flush). Non-repairable faults require
-- human operator intervention (proxy failures, unknown codes).
--
-- @param faultCode  number
-- @return boolean
function MaintenanceReport:isFaultRepairable(faultCode)
  return FAULT_REGISTRY[faultCode].isRepairable
end

-- ===========================================================================
-- History management
-- ===========================================================================

--- Log a maintenance event to the history.
-- Creates a structured log entry with metadata derived from the fault code.
-- Auto-trims oldest entries when at capacity (FIFO).
--
-- @param event  table with keys:
--   code        — number, fault code
--   description — string, optional additional context (default "")
--   timestamp   — number, os.time() (defaults to current time)
-- @return number  index (position) of new entry in the log (1-based)
function MaintenanceReport:logToHistory(event)
  local code = event.code or 0
  local entry = {
    code        = code,
    description = event.description or "",
    timestamp   = event.timestamp or os.time(),
    report      = self:toHumanReadable(code),
    severity    = self:getSeverity(code),
    isRepairable = self:isFaultRepairable(code),
  }

  -- Trim oldest entry if at capacity
  if #self._history >= self._maxHistory then
    table.remove(self._history, 1)
  end

  table.insert(self._history, entry)
  self._lastReport = entry
  return #self._history
end

--- Set the current fault code and log the event.
-- Updates the public fields `faultCode` and `isRepairable` and
-- appends a log entry to the history.
--
-- @param code         number  fault code
-- @param description  string  additional context (optional)
function MaintenanceReport:reportFault(code, description)
  code = code or 0
  self.faultCode    = code
  self.isRepairable = self:isFaultRepairable(code)
  self:logToHistory({
    code        = code,
    description = description or "",
  })
end

--- Clear the current fault and log the resolution.
-- Does nothing if there is no active fault (faultCode == 0).
--
-- @param resolutionNote  string  optional note about how the fault was cleared
-- @return boolean true if a fault was actually cleared
function MaintenanceReport:clearFault(resolutionNote)
  if self.faultCode == 0 then
    return false  -- no active fault to clear
  end

  local previousCode = self.faultCode
  self:logToHistory({
    code        = 0,
    description = "Fault cleared, previously code " .. tostring(previousCode)
                    .. (resolutionNote and (": " .. resolutionNote) or ""),
    timestamp   = os.time(),
  })
  self.faultCode    = 0
  self.isRepairable = false
  return true
end

--- Get the full maintenance history.
-- @param limit  number  max entries to return (nil = return all)
-- @return table  array of log entries, newest last
function MaintenanceReport:getHistory(limit)
  if not limit or limit >= #self._history then
    return self._history
  end
  -- Return the most recent 'limit' entries
  local offset = math.max(1, #self._history - limit + 1)
  local result = {}
  for i = offset, #self._history do
    table.insert(result, self._history[i])
  end
  return result
end

--- Get the most recent log entry.
-- @return table or nil if no events have been logged
function MaintenanceReport:getLastReport()
  return self._lastReport
end

-- ===========================================================================
-- Integration helpers
-- ===========================================================================

--- Build a flat telemetry summary for modem broadcast.
-- Used by TelemetryPayload (A7) when collecting machine state.
-- @return table  {machineId, faultCode, isRepairable, faultSummary,
--                  lastReportAt, historyCount}
function MaintenanceReport:toTelemetry()
  return {
    machineId    = self.machineId,
    faultCode    = self.faultCode,
    isRepairable = self.isRepairable,
    faultSummary = self:toHumanReadable(self.faultCode),
    lastReportAt = self._lastReport and self._lastReport.timestamp or 0,
    historyCount = #self._history,
  }
end

--- Build a multi-line textual maintenance report for display / logging.
-- Includes machine identity, current status, repair guidance, and recent
-- history entries.
-- @return string
function MaintenanceReport:toString()
  local lines = {
    "=== Maintenance Report ===",
    "Machine: " .. self.machineId,
    "Status:  " .. self:toHumanReadable(self.faultCode),
    "",
  }
  if self.faultCode ~= 0 then
    table.insert(lines, "Repairable: " .. tostring(self.isRepairable))
    table.insert(lines, "Guidance:  " .. self:getGuidance(self.faultCode))
    table.insert(lines, "")
  end
  if #self._history > 0 then
    table.insert(lines, "-- History (" .. #self._history .. " entries, latest 5 shown) --")
    local recent = self:getHistory(5)
    for _, entry in ipairs(recent) do
      local timeStr = os.date("%H:%M:%S", entry.timestamp)
      table.insert(lines, string.format("[%s] [%s] %s",
        timeStr, entry.severity, entry.report))
    end
  end
  return table.concat(lines, "\n")
end

--- Reset the report to factory defaults.
-- Clears the current fault, history, and last report reference.
function MaintenanceReport:reset()
  self.faultCode    = 0
  self.isRepairable = false
  self._history     = {}
  self._lastReport  = nil
end

return MaintenanceReport
