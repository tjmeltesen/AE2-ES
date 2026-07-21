-- mock_modules.lua
-- Mock implementations of Exec Broker sub-modules for integration testing.
-- Each mock records calls so tests can assert correct inter-module behavior.
-- These are injected via config.modules when creating an ExecBroker.

local MockModules = {}

-- ===========================================================================
-- MachineNode mock
-- ===========================================================================
MockModules.MachineNode = {}
MockModules.MachineNode.__index = MockModules.MachineNode

function MockModules.MachineNode.new(address, opts)
  opts = opts or {}
  local self = setmetatable({}, MockModules.MachineNode)
  self._address = address
  self._status = opts.status or "AVAILABLE"
  self._faulted = opts.faulted or false
  self._faultCode = opts.faultCode or 0
  self._faultDesc = opts.faultDesc or ""
  self._locked = false
  self._activeJob = nil
  self._machineType = opts.machineType or "basic"
  self.maintenanceFlags = opts.maintenanceFlags or {}
  self._callLog = {}
  self.id = opts.id or ("job_" .. address)
  self._cachedProgress = 0
  self._lastPollTime = 0
  self._healthScore  = 100       -- for quickHealthCheck
  self._healthIssues = {}        -- for quickHealthCheck
  -- hardwareAddress for HAL:getProxy() compatibility
  self.hardwareAddress = address
  self.machineType = opts.machineType or "gt_machine"
  return self
end

function MockModules.MachineNode:getStatus()
  return self._status
end

function MockModules.MachineNode:isAvailable()
  return self._status == "AVAILABLE" and not self._locked
end

function MockModules.MachineNode:lock()
  if self._status ~= "AVAILABLE" or self._locked then return false end
  self._locked = true
  self._status = "LOCKED"
  table.insert(self._callLog, "lock")
  return true
end

function MockModules.MachineNode:unlock()
  self._locked = false
  table.insert(self._callLog, "unlock")
end

function MockModules.MachineNode:bindJob(job)
  if not self._locked then return false end
  self._activeJob = job
  self._status = "PROCESSING"
  table.insert(self._callLog, "bindJob")
  return true
end

function MockModules.MachineNode:releaseJob()
  self._activeJob = nil
  self._status = "AVAILABLE"
  self._locked = false
  table.insert(self._callLog, "releaseJob")
  return true
end

function MockModules.MachineNode:hasFault()
  return self._faulted
end

function MockModules.MachineNode:clearFault()
  self._faulted = false
  self._faultCode = 0
  self._faultDesc = ""
  table.insert(self._callLog, "clearFault")
end

function MockModules.MachineNode:updateHardwareState(progress)
  self._cachedProgress = progress or 0
  self._lastPollTime = os.time()
end

function MockModules.MachineNode:updateHealth(sensorLines)
  self._healthScore  = 100
  self._healthIssues = {}
end

function MockModules.MachineNode:isHealthy()
  return (self._healthScore or 100) >= 80
end

function MockModules.MachineNode:getHealthScore()
  return self._healthScore or 100
end

function MockModules.MachineNode:getHealthIssues()
  return self._healthIssues or {}
end

function MockModules.MachineNode:recordFault(code, description)
  self._faulted = true
  self._faultCode = code or 0
  self._faultDesc = description or "Unknown fault"
  self._status = "FAULTED"
  self.maintenanceFlags = { hasFault = true, code = code or 0, description = description or "Unknown fault", timestamp = os.time() }
  table.insert(self._callLog, "recordFault:" .. (code or 0))
end

function MockModules.MachineNode:getMachineType()
  return self._machineType
end

function MockModules.MachineNode:toTelemetry()
  return {
    address = self._address,
    status = self._status,
    faulted = self._faulted,
    activeJobId = self._activeJob and self._activeJob.id or nil,
  }
end

function MockModules.MachineNode:injectFault(code, desc)
  self._faulted = true
  self._faultCode = code or 500
  self._faultDesc = desc or "Injected fault"
  self._status = "FAULTED"
  self.maintenanceFlags = { hasFault = true, code = code or 500, description = desc or "Injected fault" }
  table.insert(self._callLog, "injectFault:" .. (code or 500))
end

-- ===========================================================================
-- JobQueue mock
-- ===========================================================================
MockModules.JobQueue = {}
MockModules.JobQueue.__index = MockModules.JobQueue

function MockModules.JobQueue.new(maxSize)
  local self = setmetatable({}, MockModules.JobQueue)
  self._queue = {}
  self._maxSize = maxSize or 64
  self._pushCount = 0
  self._popCount = 0
  self._rejected = 0
  return self
end

function MockModules.JobQueue:push(job)
  if #self._queue >= self._maxSize then
    self._rejected = self._rejected + 1
    return false
  end
  table.insert(self._queue, job)
  self._pushCount = self._pushCount + 1
  return true
end

function MockModules.JobQueue:popNextAvailable()
  -- Find first PENDING job
  for i, job in ipairs(self._queue) do
    if job.status == "PENDING" then
      table.remove(self._queue, i)
      self._popCount = self._popCount + 1
      return job
    end
  end
  return nil
end

function MockModules.JobQueue:length()
  return #self._queue
end

function MockModules.JobQueue:peek()
  return self._queue[1]
end

-- ===========================================================================
-- HardwareAbstractionLayer (HAL) mock
-- ===========================================================================
MockModules.HAL = {}
MockModules.HAL.__index = MockModules.HAL

MockModules.HAL.CAP_FLUID_INPUT = "fluid_input"
MockModules.HAL.CAP_FLUID_OUTPUT = "fluid_output"
MockModules.HAL.CAP_ITEM_INPUT = "item_input"
MockModules.HAL.CAP_ITEM_OUTPUT = "item_output"

function MockModules.HAL.new(config)
  local self = setmetatable({}, MockModules.HAL)
  self._config = config or {}
  self._capabilities = config and config.capabilities or {
    basic = { "item_input", "item_output" },
    fluid = { "item_input", "item_output", "fluid_input", "fluid_output" },
  }
  self._lastError = nil
  self._drainLog = {}
  self._fluidLog = {}
  self._redstoneCalls = {}
  self._maintenanceChecks = {}
  self._mockProxies = {}     -- address -> proxy table for getProxy()
  self._pollResults = {}     -- address -> pollMachineHardware return override
  return self
end

--- Inject a mock proxy that getProxy() will return for the given address.
function MockModules.HAL:setMockProxy(address, proxy)
  self._mockProxies[address] = proxy
end

--- Override the return value of pollMachineHardware for a given address.
function MockModules.HAL:setMockPollResult(address, result)
  self._pollResults[address] = result
end

function MockModules.HAL:getProxy(address)
  if self._mockProxies[address] then
    return self._mockProxies[address]
  end
  return nil, "HAL mock: no proxy registered for " .. tostring(address)
end

function MockModules.HAL:pollMachineHardware(machineNode)
  table.insert(self._maintenanceChecks, { address = machineNode._address or machineNode.hardwareAddress, action = "pollHardware", timestamp = os.time() })
  -- Return override if set
  local addr = machineNode.hardwareAddress or machineNode._address
  if self._pollResults[addr] then
    return self._pollResults[addr]
  end
  -- Default: derive from MachineNode state
  local active = machineNode._status == "PROCESSING"
  local faulted = machineNode._faulted
  if machineNode.updateHardwareState then
    machineNode:updateHardwareState(active and 45 or 0)
  end
  return { active = active, progress = active and 45 or 0, maxProgress = 100, hasWork = active, faulted = faulted, faultReason = faulted and "mock fault" or nil, name = machineNode.machineType or "gt_machine", eu = 1000000, euCapacity = 10000000, sensorLines = {}, workAllowed = true, machineName = "mock_gt_machine" }
end

function MockModules.HAL:drainInventory(transposerAddress, fromSide, toSide)
  local entry = { addr = transposerAddress, from = fromSide, to = toSide, timestamp = os.time() }
  table.insert(self._drainLog, entry)
  return 64 -- pretend we moved 64 items
end

function MockModules.HAL:performFluidTransfer(fromSide, toSide)
  local entry = { from = fromSide, to = toSide, timestamp = os.time() }
  table.insert(self._fluidLog, entry)
  return true, 1000 -- pretend we moved 1000 mB
end

--- Mock getMEContents — returns items and fluids for the ME Controller feeder.
-- By default returns empty. Test fixtures can override via _mockMEData.
function MockModules.HAL:getMEContents(meControllerAddr)
  if self._mockMEData then
    return self._mockMEData
  end
  return { items = {}, fluids = {} }
end

function MockModules.HAL:storeDatabaseEntry(dbAddress, slot, name, damage, nbt)
  self._dbEntries = self._dbEntries or {}
  table.insert(self._dbEntries, { dbAddress = dbAddress, slot = slot, name = name, damage = damage, nbt = nbt })
  return true
end

function MockModules.HAL:storeNetworkEntry(meAddr, filter, dbAddress, slot)
  self._networkStores = self._networkStores or {}
  table.insert(self._networkStores, { meAddr = meAddr, filter = filter, dbAddress = dbAddress, slot = slot })
  return true
end

function MockModules.HAL:clearDatabaseSlot(dbAddress, slot)
  self._clearedSlots = self._clearedSlots or {}
  table.insert(self._clearedSlots, { dbAddress = dbAddress, slot = slot })
  return true
end

function MockModules.HAL:configureInterfaceStocking(ifaceAddress, slot, dbAddress, dbSlot, count)
  self._stockConfigs = self._stockConfigs or {}
  table.insert(self._stockConfigs, { ifaceAddress = ifaceAddress, slot = slot, dbAddress = dbAddress, dbSlot = dbSlot, count = count })
  return true
end

function MockModules.HAL:clearInterfaceSlot(ifaceAddress, slot)
  self._clearedIfaces = self._clearedIfaces or {}
  table.insert(self._clearedIfaces, { ifaceAddress = ifaceAddress, slot = slot })
  return true
end

function MockModules.HAL:configureFluidExport(ifaceAddress, side, dbAddress, dbSlot)
  self._fluidExports = self._fluidExports or {}
  table.insert(self._fluidExports, { ifaceAddress = ifaceAddress, side = side, dbAddress = dbAddress, dbSlot = dbSlot })
  return true
end

function MockModules.HAL:clearFluidExport(ifaceAddress, side)
  self._fluidClears = self._fluidClears or {}
  table.insert(self._fluidClears, { ifaceAddress = ifaceAddress, side = side })
  return true
end

function MockModules.HAL:checkSlotCount(side, slot)
  return self._mockSlotCount or 0
end

function MockModules.HAL:getLastError()
  return self._lastError
end

function MockModules.HAL:setLastError(err)
  self._lastError = err
end

function MockModules.HAL:hasCapability(machineType, capability)
  local caps = self._capabilities[machineType]
  if not caps then return false end
  for _, c in ipairs(caps) do
    if c == capability then return true end
  end
  return false
end

function MockModules.HAL:checkMaintenanceState(machine, transposerAddr, ifaceSide)
  table.insert(self._maintenanceChecks, { address = machine._address, timestamp = os.time() })
  if machine._faulted then
    return {
      faulted = true,
      faults = { { code = machine._faultCode or 500, description = machine._faultDesc or "Machine faulted" } },
      healthScore = 50,
      powerOk = true,
      progressOk = false,
      ghostItems = 0,
      recommendations = { "Inspect machine" },
      machineName = "mock_gt_machine",
      powerPercentage = 100,
      errorType = "machine_faulted",
      needsMaintenance = false,
      hasProblems = false,
      incompleteStructure = false,
      powerLossShutdown = false,
    }
  end
  return {
    faulted = false,
    faults = {},
    healthScore = 100,
    powerOk = true,
    progressOk = true,
    ghostItems = 0,
    recommendations = {},
    machineName = "mock_gt_machine",
    powerPercentage = 100,
    errorType = nil,
    needsMaintenance = false,
    hasProblems = false,
    incompleteStructure = false,
    powerLossShutdown = false,
  }
end

--- Lightweight pre-allocation health probe used by smart dispatch.
-- Delegates to the machine node's health state.
function MockModules.HAL:quickHealthCheck(node)
  if node._healthScore then
    return { ok = node._healthScore >= 80, healthScore = node._healthScore, issues = node._healthIssues or {} }
  end
  return { ok = true, healthScore = 100, issues = {} }
end

function MockModules.HAL:setRedstone(side, value)
  table.insert(self._redstoneCalls, { side = side, value = value, timestamp = os.time() })
end

function MockModules.HAL:setRedstoneLock(redstoneLockAddress, side, value)
  table.insert(self._redstoneCalls, { type = "setRedstoneLock", address = redstoneLockAddress, side = side, value = value, timestamp = os.time() })
  return true
end

function MockModules.HAL:pulseRedstoneLock(redstoneLockAddress, side, pulseDuration)
  table.insert(self._redstoneCalls, { type = "pulseRedstoneLock", address = redstoneLockAddress, side = side, duration = pulseDuration, timestamp = os.time() })
  return true
end

function MockModules.HAL:getRedstone(side)
  -- Return the last value set for this side, or 0
  for i = #self._redstoneCalls, 1, -1 do
    if self._redstoneCalls[i].side == side then
      return self._redstoneCalls[i].value
    end
  end
  return 0
end

function MockModules.HAL:checkInterfaceStocked(ifaceAddress, slotCount)
  table.insert(self._redstoneCalls, { type = "checkInterfaceStocked", address = ifaceAddress, slots = slotCount, timestamp = os.time() })
  return true  -- pretend interface is always stocked
end

function MockModules.HAL:getInventoryContents(transposerAddress, side)
  local entry = { addr = transposerAddress, side = side, timestamp = os.time() }
  table.insert(self._drainLog, entry)
  return {}  -- pretend inventory is empty
end

-- ===========================================================================
-- MaintenanceReport mock
-- ===========================================================================
MockModules.MaintenanceReport = {}
MockModules.MaintenanceReport.__index = MockModules.MaintenanceReport

function MockModules.MaintenanceReport.new(address)
  local self = setmetatable({}, MockModules.MaintenanceReport)
  self._address = address
  self.faultCode = 0
  self.faultMsg = nil
  self.isRepairable = true
  self._log = {}
  return self
end

function MockModules.MaintenanceReport:reportFault(code, description)
  self.faultCode = code
  self.faultMsg = description
  table.insert(self._log, { type = "fault", code = code, description = description, timestamp = os.time() })
end

function MockModules.MaintenanceReport:clearFault(message)
  self.faultCode = 0
  self.faultMsg = nil
  table.insert(self._log, { type = "clear", message = message, timestamp = os.time() })
end

function MockModules.MaintenanceReport:toHumanReadable(code)
  local messages = {
    [500] = "Internal machine error",
    [501] = "Power loss detected",
    [502] = "Input bus jammed",
    [503] = "Output bus full",
    [504] = "Transfer error",
  }
  return messages[code] or "Unknown fault code: " .. tostring(code)
end

-- ===========================================================================
-- Modem mock for supervisor integration testing
-- ===========================================================================
MockModules.MockModem = {}
MockModules.MockModem.__index = MockModules.MockModem

function MockModules.MockModem.new()
  local self = setmetatable({}, MockModules.MockModem)
  self._openPorts = {}
  self._sentMessages = {}
  self._address = "mock-modem-001"
  return self
end

function MockModules.MockModem:open(port)
  self._openPorts[port] = true
  return true
end

function MockModules.MockModem:close(port)
  self._openPorts[port] = nil
  return true
end

function MockModules.MockModem:isOpen(port)
  return self._openPorts[port] == true
end

function MockModules.MockModem:send(address, port, ...)
  table.insert(self._sentMessages, { address = address, port = port, data = {...} })
  return true
end

function MockModules.MockModem:broadcast(port, ...)
  table.insert(self._sentMessages, { address = "BROADCAST", port = port, data = {...} })
  return true
end

-- ===========================================================================
-- BufferSnapshot override for exec_broker compatibility
-- The real exec_broker expects BufferSnapshot to have:
--   .new(debounceWindow)
--   :update(bufferData) -> bool
--   :convertToManifest(index) -> manifest table
--   :reset()
--   :getSnapshotData() -> table { items, fluids }
-- ===========================================================================
MockModules.IntegrationSnapshot = {}
MockModules.IntegrationSnapshot.__index = MockModules.IntegrationSnapshot

-- We need to build this on top of the real BufferSnapshot from src/
local RealBufferSnapshot = require("src.BufferSnapshot")

function MockModules.IntegrationSnapshot.new(debounceWindow)
  local self = setmetatable({}, MockModules.IntegrationSnapshot)
  self._debounceWindow = debounceWindow or 1.0
  self._currentData = nil
  self._stable = false
  self._snapshotCount = 0
  self._lastHash = nil
  self._stableSince = nil
  -- Use os.clock() for sub-second precision (overridden in tests)
  self._clockFn = os.clock or os.time
  return self
end

function MockModules.IntegrationSnapshot:update(bufferData)
  self._snapshotCount = self._snapshotCount + 1
  self._currentData = bufferData

  -- Compute hash from buffer data
  local hash = RealBufferSnapshot.generateChecksum(bufferData and bufferData.items or {})
  local now = self._clockFn()

  if self._lastHash and hash == self._lastHash and self._stableSince ~= nil then
    local elapsed = now - self._stableSince
    if elapsed >= self._debounceWindow then
      self._stable = true
      return true
    end
  elseif hash ~= self._lastHash then
    self._stableSince = now
    self._lastHash = hash
    self._stable = false
  else
    self._stableSince = now
    self._lastHash = hash
  end

  return false
end

function MockModules.IntegrationSnapshot:convertToManifest(index)
  if not self._currentData then return nil end
  local items = self._currentData.items or {}
  local fluids = self._currentData.fluids or {}
  local manifest = {
    id = "job_" .. tostring(index or 0) .. "_" .. tostring(os.time()),
    inputs = { items = items, fluids = fluids },
    priority = 0,
    createdAt = os.time(),
    updatedAt = os.time(),
  }
  return manifest
end

function MockModules.IntegrationSnapshot:reset()
  self._stable = false
  self._lastHash = nil
  self._stableSince = nil
end

function MockModules.IntegrationSnapshot:getSnapshotData()
  return self._currentData
end

return MockModules
