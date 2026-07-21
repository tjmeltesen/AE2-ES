-- hal/maintenance.lua -- maintenance checking + sensor parsing
local HAL = require("src.hal.proxy")
-- ===========================================================================
-- Maintenance state checking (checkMaintenanceState)
-- ===========================================================================

--- Safely parse getStoredEUString() output into a number.
-- GTNH batteries (LSC, etc.) can exceed 2^32 EU; getStoredEU() overflows.
-- getStoredEUString() returns a decimal string. Lua 5.3 double-precision
-- floats represent integers exactly up to 2^53 — more than enough.
-- @param euString  string  raw EU value as string (e.g. "12345678901234567890")
-- @return number|nil  parsed EU value, or nil if unparseable
local function parseEUString(euString)
  if euString == nil or euString == "" then return nil end
  -- Strip commas and underscores (common in large-number formatting)
  local cleaned = euString:gsub("[,%s_]", "")
  return tonumber(cleaned)
end

--- Parse getSensorInformation() lines for known GT machine error states.
-- Sensor output is advisory during this trial: malformed data produces a
-- warning instead of propagating an error into the broker loop.
-- @param sensorLines  table|nil  string array from getSensorInformation()
-- @return table parsed flags and issueCount
-- @return string|nil advisory warning when sensor data cannot be parsed
function HAL:parseSensorData(sensorLines)
  local parsed = {
    powerLossShutdown = false,
    needsMaintenance = false,
    hasProblems = false,
    incompleteStructure = false,
    issueCount = 0,
  }

  if sensorLines == nil then return parsed end
  if type(sensorLines) ~= "table" then
    return parsed, "Sensor data unavailable: expected a table of lines"
  end

  local ok, err = pcall(function()
    for _, line in ipairs(sensorLines) do
      if type(line) == "string" then
        if line:find("Shut down due to power loss", 1, true) then
          parsed.powerLossShutdown = true
          parsed.issueCount = parsed.issueCount + 1
        end
        if line:find("Maintenance", 1, true) then
          parsed.needsMaintenance = true
          parsed.issueCount = parsed.issueCount + 1
        end
        if line:find("Has Problems", 1, true) then
          parsed.hasProblems = true
          parsed.issueCount = parsed.issueCount + 1
        end
        if line:find("Incomplete Structure", 1, true) then
          parsed.incompleteStructure = true
          parsed.issueCount = parsed.issueCount + 1
        end
      end
    end
  end)

  if not ok then
    return {
      powerLossShutdown = false,
      needsMaintenance = false,
      hasProblems = false,
      incompleteStructure = false,
      issueCount = 0,
    }, "Sensor data parsing failed: " .. tostring(err)
  end

  return parsed
end

--- Poll a machine's GT hardware via HAL's proxy cache and push state into
-- the MachineNode. Owns all hardware I/O — MachineNode never touches components.
-- @param machineNode  MachineNode instance
-- @return table  { active, progress, maxProgress, hasWork, faulted, faultReason, name, eu, euCapacity }
function HAL:pollMachineHardware(machineNode)
  self:clearError()

  local result = {
    active      = false,
    progress    = 0,
    maxProgress = 0,
    hasWork     = false,
    faulted     = false,
    faultReason = nil,
    name        = machineNode.machineType or "unknown",
    eu          = nil,
    euCapacity  = nil,
  }

  local proxy = self:getProxy(machineNode.hardwareAddress)
  if not proxy then
    if machineNode:getStatus() == "PROCESSING" then
      machineNode:recordFault(100, "Hardware proxy unresponsive for " .. (machineNode.hardwareAddress:sub(1,8)))
    end
    self:invalidateCache(machineNode.hardwareAddress)  -- force fresh component.proxy() next poll
    result.faulted = true
    result.faultReason = self._lastError or "proxy unavailable"
    return result
  end

  -- Read hardware state — per-call pcall so one failure doesn't blank all fields
  local active, progress, maxProgress, hasWork
  pcall(function() active      = proxy.isMachineActive() end)
  pcall(function() progress    = proxy.getWorkProgress() end)
  pcall(function() maxProgress = proxy.getWorkMaxProgress() end)
  pcall(function() hasWork     = proxy.hasWork() end)

  -- If ALL calls failed, the proxy is dead
  if active == nil and progress == nil and hasWork == nil then
    if machineNode:getStatus() == "PROCESSING" then
      machineNode:recordFault(100, "Hardware proxy unresponsive for " .. (machineNode.hardwareAddress:sub(1,8)))
    end
    self:invalidateCache(machineNode.hardwareAddress)  -- stale handle, force refresh next poll
    result.faulted = true
    result.faultReason = "all hardware calls returned nil"
    return result
  end

  result.active      = active or false
  result.progress    = progress or 0
  result.maxProgress = maxProgress or 0
  result.hasWork     = hasWork or false

  -- Read sensor, power, and identity data (per-call pcall for resilience)
  local sensorLines, euString, euCapacity, workAllowed, machineName
  pcall(function() sensorLines = proxy.getSensorInformation() end)
  pcall(function() euString    = proxy.getStoredEUString() end)
  pcall(function() euCapacity  = proxy.getEUMaxStored() end)
  pcall(function() workAllowed = proxy.isWorkAllowed() end)
  pcall(function() machineName = proxy.getName() end)

  result.sensorLines    = sensorLines
  result.eu             = parseEUString(euString)
  result.euCapacity     = euCapacity or 0
  result.workAllowed    = workAllowed
  result.machineName    = machineName or "unknown"

  -- Push progress into MachineNode
  machineNode:updateHardwareState(result.progress)

  -- Fault detection: only when PROCESSING
  if machineNode:getStatus() == "PROCESSING" then
    if active == false and hasWork then
      machineNode:recordFault(200, "Machine went inactive with work remaining")
      result.faulted = true
      result.faultReason = "inactive with work remaining"
    elseif active == false and progress and maxProgress
           and progress > 0 and progress < maxProgress then
      machineNode:recordFault(201, "Machine stalled mid-operation")
      result.faulted = true
      result.faultReason = "stalled mid-operation"
    end
  end

  return result
end

--- Perform a comprehensive maintenance check on a machine.
-- Updated doc comment
-- @param machineNode   MachineNode instance (from A2)
-- @param transposerAddr  string  optional transposer address for ghost check
-- @param ifaceSide     number  optional side for ghost check
-- @return table with keys:
--   faulted, faults, healthScore, powerOk, progressOk, ghostItems,
--   recommendations, machineName, powerPercentage, errorType,
--   needsMaintenance, hasProblems, incompleteStructure
function HAL:checkMaintenanceState(machineNode, transposerAddr, ifaceSide)
  self:clearError()

  local result = {
    faulted              = false,
    faults               = {},
    healthScore          = 100,
    powerOk              = true,
    progressOk           = true,
    ghostItems           = 0,
    recommendations      = {},
    machineName          = "unknown",
    powerPercentage      = nil,
    errorType            = nil,
    needsMaintenance     = false,
    hasProblems          = false,
    incompleteStructure  = false,
    powerLossShutdown    = false,
    advisories           = {},
  }

  if not machineNode then
    table.insert(result.faults, {
      code        = HAL.FAULT_DISCONNECTED,
      label       = "Machine Disconnected",
      description = "No machineNode reference provided to check",
    })
    result.faulted     = true
    result.healthScore = 0
    result.errorType   = "disconnected"
    return result
  end

  -- Get capabilities for this machine type
  local capabilities = self:getCapabilities(machineNode.machineType)

  -- Poll hardware through HAL (not MachineNode)
  local hardwareState = self:pollMachineHardware(machineNode)
  result.machineName = hardwareState.machineName or "unknown"
  local hasPowerCap = self:hasCapability(machineNode.machineType, HAL.CAP_POWER_EU)
                    or self:hasCapability(machineNode.machineType, HAL.CAP_POWER_STEAM)

  -- =========================================================================
  -- Phase 1: Parse sensor lines for structural / maintenance issues
  -- =========================================================================
  local sensorData, sensorWarning = self:parseSensorData(hardwareState.sensorLines)
  result.powerLossShutdown = sensorData.powerLossShutdown
  result.needsMaintenance = sensorData.needsMaintenance
  result.hasProblems = sensorData.hasProblems
  result.incompleteStructure = sensorData.incompleteStructure
  if sensorWarning then
    table.insert(result.advisories, {
      code = HAL.FAULT_SENSOR_PARSE,
      description = sensorWarning,
    })
  end

  if result.powerLossShutdown then
    result.healthScore = result.healthScore - 50
    table.insert(result.faults, {
      code        = HAL.FAULT_POWER_STARVATION,
      label       = "Power Loss Shutdown",
      description = "Machine shut down due to power loss — EU drained during operation",
      advisory    = true,
    })
    table.insert(result.recommendations,
      "Increase EU supply; machine lost power mid-recipe and may have voided inputs")
    result.powerOk = false
    result.errorType = "power_loss_shutdown"
  end

  if result.incompleteStructure then
    result.healthScore = result.healthScore - 40
    table.insert(result.faults, {
      code        = HAL.FAULT_INCOMPLETE_STRUCT,
      label       = "Incomplete Structure",
      description = "Multiblock structure is incomplete — machine cannot run",
      advisory    = true,
    })
    table.insert(result.recommendations,
      "Verify multiblock structure is complete; check all hatches and casings")
    result.errorType = "incomplete_structure"
  end

  if result.needsMaintenance then
    result.healthScore = result.healthScore - 20
    table.insert(result.faults, {
      code        = HAL.FAULT_NEEDS_MAINTENANCE,
      label       = "Maintenance Required",
      description = "Maintenance hatch requires attention",
      advisory    = true,
    })
    table.insert(result.recommendations,
      "Perform maintenance on machine with appropriate tools")
    if not result.errorType then result.errorType = "needs_maintenance" end
  end

  if result.hasProblems then
    result.healthScore = result.healthScore - 15
    table.insert(result.faults, {
      code        = HAL.FAULT_HAS_PROBLEMS,
      label       = "Machine Has Problems",
      description = "Machine reports unresolved problems",
      advisory    = true,
    })
    table.insert(result.recommendations,
      "Inspect machine GUI for specific problem details; resolve before resuming")
    if not result.errorType then result.errorType = "has_problems" end
  end

  -- =========================================================================
  -- Phase 2: Power starvation detection (real EU data from hardware)
  -- =========================================================================
  if hasPowerCap then
    local eu = hardwareState.eu
    local euCap = hardwareState.euCapacity
    if eu and euCap and euCap > 0 then
      local pct = eu / euCap
      result.powerPercentage = math.floor(pct * 100)
      if pct < 0.05 and hardwareState.active then
        result.powerOk = false
        result.healthScore = result.healthScore - 30
        table.insert(result.faults, {
          code        = HAL.FAULT_POWER_STARVATION,
          label       = "Power Starvation",
          description = string.format("EU at %.1f%% (%s / %s) while active",
            pct * 100, tostring(eu), tostring(euCap)),
        })
        table.insert(result.recommendations,
          "EU reserve critically low (< 5%); pulse redstone lock to halt input bus")
        if not result.errorType then result.errorType = "power_starvation" end
      end
    elseif hardwareState.faulted then
      -- Proxy-level fault (no EU data available)
      result.powerOk = false
      result.healthScore = result.healthScore - 30
      table.insert(result.faults, {
        code        = HAL.FAULT_PROXY_ERROR,
        label       = "Hardware Error",
        description = hardwareState.faultReason or "Unknown hardware error",
      })
      table.insert(result.recommendations,
        "Inspect machine: " .. (hardwareState.machineName or "unknown"))
    end
  end

  -- =========================================================================
  -- Phase 3: Check for item jams (hasWork but not active)
  -- =========================================================================
  if hardwareState.hasWork and not hardwareState.active then
    result.healthScore = result.healthScore - 25
    table.insert(result.faults, {
      code        = HAL.FAULT_ITEM_JAM,
      label       = "Item Jam Detected",
      description = "Machine has queued work but is not running — possible item jam or missing input",
    })
    table.insert(result.recommendations,
      "Check machine output bus for blockages; ensure input items/fluids are present")
    if not result.errorType then result.errorType = "item_jam" end
  end

  -- =========================================================================
  -- Phase 4: Check for ghost items in the ME interface
  -- =========================================================================
  if transposerAddr and ifaceSide then
    local transposer, tErr = self:getProxy(transposerAddr)
    if transposer then
      local sizeOk, size = pcall(transposer.getInventorySize, transposer, ifaceSide)
      if sizeOk and size and size > 0 then
        local ghostCount = 0
        for slot = 1, size do
          local stackOk, stack = pcall(transposer.getStackInSlot, transposer, ifaceSide, slot)
          if stackOk and stack then
            local sz = stack.size
            if not sz or sz <= 0 then
              local cntOk, cnt = pcall(transposer.getSlotStackSize, transposer, ifaceSide, slot)
              if cntOk and type(cnt) == "number" then sz = cnt end
            end
            if sz and sz > 0 then
              ghostCount = ghostCount + sz
            end
          end
          os.sleep(0)  -- yield per slot
        end
        result.ghostItems = ghostCount
        if ghostCount > 0 then
          result.healthScore = result.healthScore - 15
          table.insert(result.faults, {
            code        = HAL.FAULT_GHOST_ITEMS,
            label       = "Ghost Items in Interface",
            description = "Found " .. tostring(ghostCount) .. " items stranded in the ME interface",
          })
          table.insert(result.recommendations,
            "Run flushInterface() to clear ghost items from interface")
        end
      end
    end
  end

  -- =========================================================================
  -- Phase 5: Check machine status flag from MachineNode
  -- =========================================================================
  if machineNode:isFaulted() then
    result.healthScore = result.healthScore - 20
    if #result.faults == 0 then
      table.insert(result.faults, {
        code        = HAL.FAULT_PROXY_ERROR,
        label       = "Machine FAULTED",
        description = "MachineNode reports FAULTED status flag",
      })
      table.insert(result.recommendations,
        "Check machine for hardware or software faults; consider maintenance cycle")
    end
    if not result.errorType then result.errorType = "machine_faulted" end
  end

  -- Clamp health score
  if result.healthScore < 0 then
    result.healthScore = 0
  end
  result.faulted = #result.faults > 0

  return result
end

--- Lightweight pre-allocation health probe.
-- Checks hardware flags first (stuck, disabled, faulted), then parses
-- sensor text for structural/maintenance issues. Designed for the
-- allocating phase — no maintenance-state walk, no ghost-item scan.
-- @param node  MachineNode instance
-- @return table { ok, healthScore, issues }
function HAL:quickHealthCheck(node)
  local proxy = self:getProxy(node.hardwareAddress)
  if not proxy then
    return { ok = false, healthScore = 0, issues = { "proxy_unavailable" } }
  end

  -- Hardware state flags (per-call pcall)
  local hasWork, isActive, workAllowed
  pcall(function() hasWork     = proxy.hasWork() end)
  pcall(function() isActive    = proxy.isMachineActive() end)
  pcall(function() workAllowed = proxy.isWorkAllowed() end)

  if hasWork == true and isActive == false then
    return { ok = false, healthScore = 0, issues = { "stuck_inactive" } }
  end
  if workAllowed == false then
    return { ok = false, healthScore = 0, issues = { "work_disabled" } }
  end
  if node:hasFault() then
    return { ok = false, healthScore = 0, issues = { "machine_faulted" } }
  end

  -- Sensor text parsing
  local sensorLines
  pcall(function() sensorLines = proxy.getSensorInformation() end)

  if sensorLines then
    node:updateHealth(sensorLines)
    return {
      ok          = node:isHealthy(),
      healthScore = node:getHealthScore(),
      issues      = node:getHealthIssues(),
    }
  end

  return { ok = true, healthScore = 100, issues = {} }
end


return HAL
