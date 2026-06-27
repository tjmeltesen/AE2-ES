-- exec_broker/maintenance_report.lua
-- AE2-ES MaintenanceReport Module
-- Diagnostic component generated on machine faults.
-- Provides human-readable fault descriptions for the Supervisor dashboard.
-- Reports are stored in memory only (flushed on reboot), capped at 100 entries.

local MaintenanceReport = {}

-- ===========================================================================
-- Fault Code Constants
-- ===========================================================================

MaintenanceReport.FAULT_CODES = {
  STATUS_FAULTED_GENERIC     = "STATUS_FAULTED_GENERIC",
  STATUS_FAULTED_TRANSFER    = "STATUS_FAULTED_TRANSFER",
  STATUS_FAULTED_INTERFACE   = "STATUS_FAULTED_INTERFACE",
  STATUS_FAULTED_POWER       = "STATUS_FAULTED_POWER",
  STATUS_FAULTED_MAINTENANCE = "STATUS_FAULTED_MAINTENANCE",
  STATUS_FAULTED_GHOST       = "STATUS_FAULTED_GHOST",
}

local FC = MaintenanceReport.FAULT_CODES

-- ===========================================================================
-- Fault Code Metadata: labels and player guidance
-- ===========================================================================

local FAULT_LABELS = {
  [FC.STATUS_FAULTED_GENERIC]     = "Unknown Hardware Fault",
  [FC.STATUS_FAULTED_TRANSFER]    = "Transfer Failure",
  [FC.STATUS_FAULTED_INTERFACE]   = "ME Interface Unresponsive",
  [FC.STATUS_FAULTED_POWER]       = "Machine Power Loss",
  [FC.STATUS_FAULTED_MAINTENANCE] = "Maintenance Required",
  [FC.STATUS_FAULTED_GHOST]       = "Ghost Items Detected",
}

local FAULT_ACTIONS = {
  [FC.STATUS_FAULTED_GENERIC]     = "Inspect machine hardware connections and try power cycling the controller.",
  [FC.STATUS_FAULTED_TRANSFER]    = "Check transposer connectivity and ensure sufficient buffer space. Verify item/fluid routing configuration.",
  [FC.STATUS_FAULTED_INTERFACE]   = "Verify ME Interface is online and connected to the AE2 subnet. Check channel availability.",
  [FC.STATUS_FAULTED_POWER]       = "Check energy supply to the machine. Verify cables, battery buffers, and generator output.",
  [FC.STATUS_FAULTED_MAINTENANCE] = "Open machine maintenance GUI and replace worn components (rotor, coil, etc.). Check maintenance hatch.",
  [FC.STATUS_FAULTED_GHOST]       = "Purge input bus of ghost items. Flush interface and re-validate buffer contents.",
}

-- ===========================================================================
-- Internal State
-- ===========================================================================

local MAX_HISTORY = 100
local FAULT_HISTORY = {}

-- ===========================================================================
-- Private Helpers
-- ===========================================================================

--- Format a Unix epoch timestamp into a human-readable datetime string.
-- Uses os.date if available (OC Lua 5.3), falls back to raw epoch.
-- @param epoch number Unix timestamp in seconds
-- @return string Formatted timestamp
local function _format_timestamp(epoch)
  if os.date then
    local ok, result = pcall(os.date, "%Y-%m-%d %H:%M:%S", epoch)
    if ok then
      return result
    end
  end
  -- Fallback: return raw epoch as string
  return tostring(epoch)
end

--- Extract a safe node address string.
-- @param node table|nil MachineNode or nil
-- @return string address string
local function _node_address(node)
  if node and node.hardwareAddress then
    return node.hardwareAddress
  end
  return "unknown"
end

--- Build a human-readable job summary from the node's active job.
-- @param node table|nil MachineNode
-- @return string job summary or "(none)"
local function _job_summary(node)
  if not node or not node.activeJob then
    return "(none)"
  end
  local job = node.activeJob
  local parts = {}
  if job.id then
    parts[#parts + 1] = "Job#" .. tostring(job.id)
  end
  if job.state then
    parts[#parts + 1] = "[" .. tostring(job.state) .. "]"
  end
  if job.priority then
    parts[#parts + 1] = "pri=" .. tostring(job.priority)
  end
  if job.machine and job.machine.hardwareAddress then
    parts[#parts + 1] = "target=" .. tostring(job.machine.hardwareAddress)
  end
  if #parts == 0 then
    return "(active job, no summary available)"
  end
  return table.concat(parts, " ")
end

--- Build a details block from sensor information or node context.
-- @param node table|nil MachineNode
-- @return string details text or "(no sensor data available)"
local function _build_details(node)
  -- Prefer sensor information if the node carries it
  if node and node.sensorInformation then
    if type(node.sensorInformation) == "table" then
      local lines = {}
      for _, line in ipairs(node.sensorInformation) do
        lines[#lines + 1] = "    " .. tostring(line)
      end
      return table.concat(lines, "\n")
    end
    return "    " .. tostring(node.sensorInformation)
  end

  -- Context-dependent details when no sensor info is available
  if node then
    local parts = {}
    if node.maintenanceFlags and type(node.maintenanceFlags) == "table" then
      local flags = {}
      for _, flag in ipairs(node.maintenanceFlags) do
        flags[#flags + 1] = tostring(flag)
      end
      if #flags > 0 then
        parts[#parts + 1] = "Maintenance Flags: " .. table.concat(flags, ", ")
      end
    end
    if node.interfaceAddress then
      parts[#parts + 1] = "Interface: " .. tostring(node.interfaceAddress)
    end
    if node.status then
      parts[#parts + 1] = "Machine Status: " .. tostring(node.status)
    end
    if #parts > 0 then
      return "    " .. table.concat(parts, "\n    ")
    end
  end

  return "    (no sensor data available)"
end

-- ===========================================================================
-- Report Instance Methods (shared prototype)
-- ===========================================================================

local ReportPrototype = {}

--- Convert the report to a human-readable formatted string.
-- Format:
--   [YYYY-MM-DD HH:MM:SS] MachineNode [address] FAULT: [code]
--     Details: [sensor information / stack traces]
--     Active Job: [job summary]
--     Suggested Action: [player guidance]
-- @return string Formatted fault report
function ReportPrototype:toHumanReadable()
  local lines = {}

  -- Header line
  local ts = _format_timestamp(self.timestamp)
  local label = FAULT_LABELS[self.fault_code] or self.fault_code
  lines[#lines + 1] = string.format(
    "[%s] MachineNode [%s] FAULT: %s",
    ts, self.node_address, label
  )

  -- Details
  lines[#lines + 1] = "  Details:"
  lines[#lines + 1] = _build_details(self._node)

  -- Active Job
  lines[#lines + 1] = "  Active Job: " .. _job_summary(self._node)

  -- Suggested Action
  local action = FAULT_ACTIONS[self.fault_code]
    or "Manually inspect the machine and check system logs for details."
  lines[#lines + 1] = "  Suggested Action: " .. action

  return table.concat(lines, "\n")
end

--- Append this report to the persistent fault log.
-- Automatically trims history to MAX_HISTORY entries (oldest removed first).
function ReportPrototype:logToHistory()
  -- Make a standalone copy without the _node reference
  -- (nodes may be nilled during cleanup; store only the data we need)
  local entry = {
    timestamp    = self.timestamp,
    node_address = self.node_address,
    fault_code   = self.fault_code,
    fault_label  = FAULT_LABELS[self.fault_code] or self.fault_code,
    fault_action = FAULT_ACTIONS[self.fault_code],
  }

  -- Capture node context at log time (if still available)
  if self._node then
    if self._node.status then
      entry.node_status = self._node.status
    end
    if self._node.interfaceAddress then
      entry.node_interface = self._node.interfaceAddress
    end
    if self._node.maintenanceFlags then
      entry.maintenance_flags = self._node.maintenanceFlags
    end
  end

  -- Append and enforce cap
  FAULT_HISTORY[#FAULT_HISTORY + 1] = entry
  while #FAULT_HISTORY > MAX_HISTORY do
    table.remove(FAULT_HISTORY, 1)
  end
end

-- ===========================================================================
-- Report Object Factory
-- ===========================================================================

--- Create a new fault report object with metatable-linked prototype methods.
-- @param node table|nil The MachineNode that faulted (or nil if unknown)
-- @param fault_code string One of MaintenanceReport.FAULT_CODES.*
-- @return table report object with :toHumanReadable() and :logToHistory() methods
local function _new_report(node, fault_code)
  local report = {
    timestamp    = os.time(),
    node_address = _node_address(node),
    fault_code   = fault_code,
    _node        = node,   -- reference retained for deferred context
  }
  setmetatable(report, { __index = ReportPrototype })
  return report
end

-- ===========================================================================
-- Public API: Module-level
-- ===========================================================================

--- Generate a new MaintenanceReport from a MachineNode and fault code.
-- The report is NOT automatically logged — call report:logToHistory() to persist.
-- @param node table|nil MachineNode abstraction that faulted
-- @param fault_code string One of MaintenanceReport.FAULT_CODES.*
-- @return table Report object with :toHumanReadable() and :logToHistory() methods
function MaintenanceReport.generate(node, fault_code)
  if not fault_code then
    error("MaintenanceReport.generate: fault_code is required")
  end
  if not FAULT_LABELS[fault_code] then
    error("MaintenanceReport.generate: unknown fault_code '" .. tostring(fault_code) .. "'")
  end
  return _new_report(node, fault_code)
end

--- Retrieve all past fault reports (most recent last).
-- @return table Array of report objects, capped at MAX_HISTORY
function MaintenanceReport.getHistory()
  return FAULT_HISTORY
end

--- Clear all fault history. Useful for testing or manual resets.
function MaintenanceReport.clearHistory()
  FAULT_HISTORY = {}
end

--- Get the current history count.
-- @return number Number of reports in history
function MaintenanceReport.getHistoryCount()
  return #FAULT_HISTORY
end

--- Get the human-readable label for a fault code.
-- @param fault_code string One of MaintenanceReport.FAULT_CODES.*
-- @return string Human-readable label, or fault_code if unknown
function MaintenanceReport.getFaultLabel(fault_code)
  return FAULT_LABELS[fault_code] or fault_code
end

--- Get the suggested player action for a fault code.
-- @param fault_code string One of MaintenanceReport.FAULT_CODES.*
-- @return string Suggested action, or a generic message if unknown
function MaintenanceReport.getFaultAction(fault_code)
  return FAULT_ACTIONS[fault_code]
    or "Manually inspect the machine and check system logs for details."
end

-- ===========================================================================
-- Return Module
-- ===========================================================================

return MaintenanceReport
