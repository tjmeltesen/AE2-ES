-- Canonical MaintenanceReport domain module. Safe to import outside OpenComputers.

local BoundedList = require("lib.bounded_list")

local MaintenanceReport = {}
MaintenanceReport.__index = MaintenanceReport

MaintenanceReport.SEVERITY = { INFO = "INFO", WARNING = "WARNING", CRITICAL = "CRITICAL" }

local S = MaintenanceReport.SEVERITY
local DEFAULT_MAX_HISTORY = 100
local EVENT_NAMES = {
  [S.INFO] = "ae2es:log_info",
  [S.WARNING] = "ae2es:log_warning",
  [S.CRITICAL] = "ae2es:log_error",
}
local FAULT_REGISTRY = {
  [0] = { severity = S.INFO, message = "No Fault — machine operating normally",
    isRepairable = false, guidance = "No action needed" },
  [1] = { severity = S.CRITICAL, message = "Power Starvation — EU supply critically low or absent",
    isRepairable = true, guidance = "Check EU supply line: verify cables, generators, and AE2 power budget" },
  [2] = { severity = S.WARNING, message = "Item Jam — machine has queued work but is not actively processing",
    isRepairable = true, guidance = "Check output bus for blockages and ensure input items/fluids are stocked" },
  [3] = { severity = S.WARNING, message = "Fluid Issue — machine has work but fluid supply or output is blocked",
    isRepairable = true, guidance = "Verify fluid input hatch supply and output hatch for full tanks" },
  [4] = { severity = S.WARNING, message = "Ghost Items — stranded items detected in ME interface after job completion",
    isRepairable = true, guidance = "Initiate interface flush to clear residual items; check transposer routing" },
  [5] = { severity = S.WARNING, message = "No Recipe — machine has no valid recipe configured for current inputs",
    isRepairable = true, guidance = "Verify ME interface pattern configuration or check input item types" },
  [6] = { severity = S.CRITICAL, message = "Overflow — machine output buffer is full, preventing job completion",
    isRepairable = true, guidance = "Clear output bus or output hatch to free space for new products" },
  [7] = { severity = S.CRITICAL, message = "Disconnected — machine component is unreachable or offline",
    isRepairable = true, guidance = "Verify adapter/MFU connection; check chunk loading and cable routing" },
  [8] = { severity = S.CRITICAL, message = "Proxy Error — OC component proxy returned an error",
    isRepairable = false, guidance = "Restart OC computer or re-connect component; check for mod conflicts" },
  [9] = { severity = S.WARNING, message = "Needs Maintenance — maintenance hatch requires attention",
    isRepairable = true, guidance = "Perform maintenance on machine with appropriate tools (screwdriver, hammer, etc.)" },
  [10] = { severity = S.WARNING, message = "Has Problems — machine reports unresolved problem state",
    isRepairable = true, guidance = "Inspect machine GUI for specific problem details; resolve before resuming" },
  [11] = { severity = S.CRITICAL, message = "Incomplete Structure — multiblock structure is missing required blocks",
    isRepairable = true, guidance = "Verify all hatches, casings, and structural blocks are correctly placed" },
}

local function registryEntry(code)
  return FAULT_REGISTRY[code] or {
    severity = S.WARNING,
    message = "Unknown Fault #" .. tostring(code),
    isRepairable = false,
    guidance = "Manual inspection required — fault code not in registry",
  }
end

local function publishLogEvent(entry, machineId)
  local eventApi = rawget(_G, "event")
  local eventName = EVENT_NAMES[entry.severity]
  if not eventName or type(eventApi) ~= "table" or type(eventApi.push) ~= "function" then
    return
  end

  pcall(eventApi.push, eventName, {
    originId = machineId,
    severity = entry.severity,
    message = entry.description ~= "" and entry.description or entry.report,
    report = entry.report,
    timestamp = entry.timestamp,
  })
end

function MaintenanceReport.new(machineId)
  return setmetatable({
    machineId = machineId or "unknown",
    faultCode = 0,
    isRepairable = false,
    _history = BoundedList.new(DEFAULT_MAX_HISTORY),
    _maxHistory = DEFAULT_MAX_HISTORY,
    _lastReport = nil,
  }, MaintenanceReport)
end

function MaintenanceReport:toHumanReadable(faultCode)
  local entry = registryEntry(faultCode)
  if entry.severity == S.INFO then return entry.message end
  return string.format("[%s] %s", entry.severity, entry.message)
end

function MaintenanceReport:getSeverity(faultCode) return registryEntry(faultCode).severity end
function MaintenanceReport:getGuidance(faultCode) return registryEntry(faultCode).guidance end
function MaintenanceReport:isFaultRepairable(faultCode) return registryEntry(faultCode).isRepairable end

function MaintenanceReport:logToHistory(event)
  event = event or {}
  local code = event.code or 0
  local entry = {
    code = code,
    description = event.description or "",
    timestamp = event.timestamp or os.time(),
    report = self:toHumanReadable(code),
    severity = self:getSeverity(code),
    isRepairable = self:isFaultRepairable(code),
  }
  self._history._maxSize = self._maxHistory
  self._history._trimTarget = self._maxHistory
  self._history:push(entry)
  self._lastReport = entry
  publishLogEvent(entry, self.machineId)
  return self._history:size()
end

function MaintenanceReport:reportFault(code, description)
  code = code or 0
  self.faultCode = code
  self.isRepairable = self:isFaultRepairable(code)
  self:logToHistory({ code = code, description = description or "" })
end

function MaintenanceReport:clearFault(resolutionNote)
  if self.faultCode == 0 then return false end
  local previousCode = self.faultCode
  self:logToHistory({
    code = 0,
    description = "Fault cleared, previously code " .. tostring(previousCode)
      .. (resolutionNote and (": " .. resolutionNote) or ""),
    timestamp = os.time(),
  })
  self.faultCode, self.isRepairable = 0, false
  return true
end

function MaintenanceReport:getHistory(limit)
  local history = self._history:toTable()
  if not limit or limit >= self._history:size() then return history end
  local result = {}
  for i = math.max(1, self._history:size() - limit + 1), self._history:size() do
    table.insert(result, history[i])
  end
  return result
end

function MaintenanceReport:getLastReport() return self._lastReport end

function MaintenanceReport:toTelemetry()
  return {
    machineId = self.machineId,
    faultCode = self.faultCode,
    isRepairable = self.isRepairable,
    faultSummary = self:toHumanReadable(self.faultCode),
    lastReportAt = self._lastReport and self._lastReport.timestamp or 0,
    historyCount = self._history:size(),
  }
end

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
  if self._history:size() > 0 then
    table.insert(lines, "-- History (" .. self._history:size() .. " entries, latest 5 shown) --")
    for _, entry in ipairs(self:getHistory(5)) do
      table.insert(lines, string.format("[%s] [%s] %s",
        os.date("%H:%M:%S", entry.timestamp), entry.severity, entry.report))
    end
  end
  return table.concat(lines, "\n")
end

function MaintenanceReport:reset()
  self.faultCode, self.isRepairable = 0, false
  self._history:clear()
  self._lastReport = nil
end

return MaintenanceReport
