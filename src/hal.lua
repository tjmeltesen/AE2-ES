--[[
hardware_abstraction_layer.lua — HardwareAbstractionLayer (HAL)
AE2 Execution System (AE2-ES)
Part of Deliverable A: Exec Broker, Module A5

Middleware translating abstract broker commands (performInventoryTransfer,
checkMaintenanceState) into OC component API calls. Provides:

  1. Component proxy caching — create once, reuse; invalidate on disconnect.
  2. Capability flags — bitmask per machine type describing what it supports.
  3. Inventory/fluid transfer — wraps transposer with error handling + yield.
  4. Maintenance state checking — structured health report from poll results.
  5. Side resolution — maps logical roles (inputBus, inputHatch, etc.) to
     side constants, configurable per broker.

Dependencies: OC component, sides, transposer libraries
Used by:      Exec Broker main loop (A8), MachineNode (A2), MaintenanceReport (A6)
]]--

local component = require("component")
local sides = require("sides")

local HAL = {}
HAL.__index = HAL

-- ===========================================================================
-- Capability flags (bitmask)
-- ===========================================================================
-- Each flag describes a hardware capability that a machine type may possess.

HAL.CAP_ITEM_INPUT        = 1       -- Machine accepts item inputs (input bus)
HAL.CAP_ITEM_OUTPUT       = 2       -- Machine produces item outputs (output bus)
HAL.CAP_FLUID_INPUT       = 4       -- Machine accepts fluid inputs (input hatch)
HAL.CAP_FLUID_OUTPUT      = 8       -- Machine produces fluid outputs (output hatch)
HAL.CAP_POWER_EU          = 16      -- Machine uses EU for processing
HAL.CAP_POWER_STEAM       = 32      -- Machine uses steam for processing
HAL.CAP_RECIPE_SELECT     = 64      -- Machine supports programmatic recipe selection
HAL.CAP_MAINTENANCE_HATCH = 128     -- Multiblock machine with maintenance hatch
HAL.CAP_PARALLEL          = 256     -- Machine supports parallel processing
HAL.CAP_OVERCLOCK         = 512     -- Machine supports overclocking

-- Aggregate: common machine profiles
HAL.CAP_PROFILE_BASIC     = HAL.CAP_ITEM_INPUT | HAL.CAP_ITEM_OUTPUT | HAL.CAP_POWER_EU
HAL.CAP_PROFILE_FLUID     = HAL.CAP_ITEM_INPUT | HAL.CAP_ITEM_OUTPUT | HAL.CAP_FLUID_INPUT | HAL.CAP_FLUID_OUTPUT | HAL.CAP_POWER_EU
HAL.CAP_PROFILE_STEAM     = HAL.CAP_ITEM_INPUT | HAL.CAP_ITEM_OUTPUT | HAL.CAP_POWER_STEAM
HAL.CAP_PROFILE_MULTI     = HAL.CAP_ITEM_INPUT | HAL.CAP_ITEM_OUTPUT | HAL.CAP_FLUID_INPUT | HAL.CAP_FLUID_OUTPUT | HAL.CAP_POWER_EU | HAL.CAP_MAINTENANCE_HATCH

-- ===========================================================================
-- Fault codes (extended, maps to and from MachineNode maintenance flags)
-- ===========================================================================
HAL.FAULT_NONE            = 0
HAL.FAULT_POWER_STARVATION  = 1
HAL.FAULT_ITEM_JAM          = 2
HAL.FAULT_FLUID_ISSUE       = 3
HAL.FAULT_GHOST_ITEMS       = 4
HAL.FAULT_NO_RECIPE         = 5
HAL.FAULT_OVERFLOW          = 6
HAL.FAULT_DISCONNECTED      = 7
HAL.FAULT_PROXY_ERROR       = 8

-- ===========================================================================
-- Default side mapping for logical roles
-- ===========================================================================
local DEFAULT_SIDE_MAP = {
  inputBus    = sides.north,     -- Where items come in (machine input bus)
  inputHatch  = sides.west,      -- Where fluid comes in (machine input hatch)
  interface   = sides.top,       -- Adjacent ME Interface
  itemBuffer  = sides.bottom,    -- Storage Drawers (item buffer)
  fluidBuffer = sides.top,       -- Fluid Hatch (fluid buffer)
  transposerInput  = sides.north,  -- Transposer pulls from drawer here
  transposerOutput = sides.south,  -- Transposer pushes into machine here
}

-- ===========================================================================
-- Known machine type -> capability mapping
-- ===========================================================================
local CAPABILITY_REGISTRY = {
  -- Standard single-block GT machines
  gt_machine                = HAL.CAP_PROFILE_BASIC,
  -- Multiblocks / special types (filled in by broker config or discovery)
}

-- ===========================================================================
-- Constructor
-- ===========================================================================

--- Create a new HardwareAbstractionLayer instance.
-- @param overrides  optional table with keys:
--   sideMap       — table overriding DEFAULT_SIDE_MAP role->side mappings
--   cacheTTL      — number, seconds before auto-refreshing a cached proxy (default 300)
--   capabilityMap — table mapping machineType string to capability flags
-- @return HAL instance
function HAL:new(overrides)
  overrides = overrides or {}
  local self = setmetatable({}, HAL)

  -- Side resolution map (merge defaults with overrides)
  self._sideMap = {}
  for role, side in pairs(DEFAULT_SIDE_MAP) do
    self._sideMap[role] = side
  end
  if overrides.sideMap then
    for role, side in pairs(overrides.sideMap) do
      self._sideMap[role] = side
    end
  end

  -- Component proxy cache: address -> { proxy, timestamp }
  self._proxyCache   = {}
  self._cacheTTL     = overrides.cacheTTL or 300

  -- Capability registry (merge defaults with overrides)
  self._capMap = {}
  for mtype, flags in pairs(CAPABILITY_REGISTRY) do
    self._capMap[mtype] = flags
  end
  if overrides.capabilityMap then
    for mtype, flags in pairs(overrides.capabilityMap) do
      self._capMap[mtype] = flags
    end
  end

  -- Last error message (cleared on each operation)
  self._lastError = nil

  return self
end

-- ===========================================================================
-- Component proxy management
-- ===========================================================================

--- Get (or create) a cached OC component proxy for the given address.
-- Returns the cached proxy if it exists and is younger than cacheTTL.
-- Otherwise creates a new proxy via component.proxy().
-- @param address  string, OC component address
-- @return proxy object, or nil + errorMessage on failure
function HAL:getProxy(address)
  if type(address) ~= "string" or address == "" then
    self._lastError = "HAL:getProxy() — invalid address"
    return nil, self._lastError
  end

  -- Check cache
  local cached = self._proxyCache[address]
  if cached then
    local age = os.time() - cached.timestamp
    if age < self._cacheTTL then
      return cached.proxy
    end
  end

  -- Create new proxy
  local ok, proxy = pcall(component.proxy, address)
  if not ok or not proxy then
    self._proxyCache[address] = nil  -- clear stale entry
    self._lastError = "HAL:getProxy() — component.proxy failed for " .. address
    return nil, self._lastError
  end

  -- Cache it
  self._proxyCache[address] = {
    proxy     = proxy,
    timestamp = os.time(),
  }
  return proxy
end

--- Invalidate a cached proxy so the next getProxy() call refreshes it.
-- Use when a component disconnect or error is detected.
-- @param address  string, OC component address (optional; nil clears all)
function HAL:invalidateCache(address)
  if address then
    self._proxyCache[address] = nil
  else
    -- Clear entire cache
    self._proxyCache = {}
  end
end

--- Get the last error message from any HAL operation.
-- @return string or nil
function HAL:getLastError()
  return self._lastError
end

--- Clear the last error message.
function HAL:clearError()
  self._lastError = nil
end

-- ===========================================================================
-- Capability queries
-- ===========================================================================

--- Get the capability flags for a given machine type.
-- Falls back to CAP_PROFILE_BASIC for unrecognised types.
-- @param machineType  string (e.g. "gt_machine")
-- @return number (bitmask)
function HAL:getCapabilities(machineType)
  if not machineType then
    return HAL.CAP_PROFILE_BASIC
  end
  return self._capMap[machineType] or HAL.CAP_PROFILE_BASIC
end

--- Register a machine type's capability flags at runtime.
-- This allows the broker to register discovered machine types on the fly.
-- @param machineType  string
-- @param flags        number (bitmask of CAP_* constants)
function HAL:registerCapabilities(machineType, flags)
  if type(machineType) ~= "string" then
    self._lastError = "HAL:registerCapabilities() — machineType must be a string"
    return false
  end
  if type(flags) ~= "number" then
    self._lastError = "HAL:registerCapabilities() — flags must be a number"
    return false
  end
  self._capMap[machineType] = flags
  return true
end

--- Check if a machine type has a specific capability.
-- @param machineType  string
-- @param flag         number — one of the CAP_* constants
-- @return boolean
function HAL:hasCapability(machineType, flag)
  local caps = self:getCapabilities(machineType)
  return (caps & flag) ~= 0
end

-- ===========================================================================
-- Side resolution
-- ===========================================================================

--- Resolve a logical role name to a side constant.
-- @param role  string — one of "inputBus", "inputHatch",
--              "itemBuffer", "fluidBuffer", "transposerInput", "transposerOutput"
-- @return number (side constant) or nil if role unknown
function HAL:resolveSide(role)
  local side = self._sideMap[role]
  if side == nil then
    self._lastError = "HAL:resolveSide() — unknown role '" .. tostring(role) .. "'"
    return nil
  end
  return side
end

--- Update the side mapping for a specific role at runtime.
-- @param role  string
-- @param side  number (side constant)
function HAL:setSideMapping(role, side)
  self._sideMap[role] = side
  return true
end

-- ===========================================================================
-- Inventory transfer operations (performInventoryTransfer)
-- ===========================================================================

--- Transfer items between two adjacent inventories via transposer.
-- Wraps transposer.transferItem() with pcall error handling.
-- Yields (os.sleep(0)) after each slot when count is nil (full transfer).
-- @param fromSide  number — source side constant
-- @param toSide    number — destination side constant
-- @param count     number|nil — max items to transfer (nil = all)
-- @param fromSlot  number|nil — source slot (nil = any)
-- @param toSlot    number|nil — destination slot (nil = any)
-- @return number of items transferred, or nil + errorMessage on failure
function HAL:performInventoryTransfer(fromSide, toSide, count, fromSlot, toSlot)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:performInventoryTransfer() — transposer not available"
    return nil, self._lastError
  end

  local transposer = component.transposer
  local ok, result = pcall(transposer.transferItem, transposer, fromSide, toSide, count, fromSlot, toSlot)

  if not ok then
    self._lastError = "HAL:performInventoryTransfer() — transposer error: " .. tostring(result)
    return nil, self._lastError
  end

  -- Yield after each transfer to avoid TMI errors
  os.sleep(0)
  return result or 0
end

--- Transfer all items from one inventory to another, slot by slot.
-- Iterates all occupied slots in the source and transfers each.
-- @param fromSide  number — source side constant
-- @param toSide    number — destination side constant
-- @return number of total items transferred, or nil + error
function HAL:drainInventory(fromSide, toSide)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:drainInventory() — transposer not available"
    return nil, self._lastError
  end

  local transposer = component.transposer
  local total = 0

  local sizeOk, size = pcall(transposer.getInventorySize, transposer, fromSide)
  if not sizeOk or not size or size < 1 then
    return 0  -- empty or unreachable, nothing to drain
  end

  for slot = 1, size do
    local stackOk, stack = pcall(transposer.getStackInSlot, transposer, fromSide, slot)
    if stackOk and stack and stack.size and stack.size > 0 then
      local okMove, moved = pcall(transposer.transferItem, transposer, fromSide, toSide, stack.size, slot, nil)
      if okMove and moved then
        total = total + moved
      end
    end
    -- Yield between slots
    os.sleep(0)
  end

  return total
end

--- Get a snapshot of all items in an inventory.
-- @param side  number — side constant
-- @return table array of {slot, label, size, maxSize, hasNBT}, or nil + error
function HAL:getInventoryContents(side)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:getInventoryContents() — transposer not available"
    return nil, self._lastError
  end

  local transposer = component.transposer
  local sizeOk, size = pcall(transposer.getInventorySize, transposer, side)
  if not sizeOk or not size then
    self._lastError = "HAL:getInventoryContents() — cannot get inventory size"
    return nil, self._lastError
  end

  local contents = {}
  for slot = 1, size do
    local stackOk, stack = pcall(transposer.getStackInSlot, transposer, side, slot)
    if stackOk and stack then
      table.insert(contents, {
        slot    = slot,
        label   = stack.label,
        size    = stack.size,
        maxSize = stack.maxSize,
        hasNBT  = stack.hasNBT or false,
        name    = stack.name,     -- mod:id format when available
      })
    end
    os.sleep(0)
  end

  return contents
end

--- Check whether an inventory slot is empty.
-- @param side  number — side constant
-- @param slot  number — slot index (1-based)
-- @return boolean, or nil + error
function HAL:isSlotEmpty(side, slot)
  self:clearError()
  if not component.isAvailable("transposer") then
    self._lastError = "HAL:isSlotEmpty() — transposer not available"
    return nil, self._lastError
  end
  local ok, stack = pcall(component.transposer.getStackInSlot, component.transposer, side, slot)
  if not ok then
    return nil  -- cannot determine, treat as error
  end
  return stack == nil or stack.size == nil or stack.size == 0
end

-- ===========================================================================
-- Fluid transfer operations
-- ===========================================================================

--- Transfer fluid between two adjacent tanks via transposer.
-- Wraps transposer.transferFluid() with pcall error handling.
-- @param fromSide   number — source side constant
-- @param toSide     number — destination side constant
-- @param count      number|nil — max mB to transfer (nil = all)
-- @param fromTank   number|nil — source tank index (nil = first)
-- @return number of mB transferred, or nil + error
function HAL:performFluidTransfer(fromSide, toSide, count, fromTank)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:performFluidTransfer() — transposer not available"
    return nil, self._lastError
  end

  local transposer = component.transposer
  local ok, ok2, transferred = pcall(transposer.transferFluid, transposer, fromSide, toSide, count, fromTank)

  if not ok then
    self._lastError = "HAL:performFluidTransfer() — transposer error: " .. tostring(ok2)
    return nil, self._lastError
  end

  os.sleep(0)
  return transferred or 0
end

--- Get a snapshot of all fluids in tanks on a given side.
-- @param side  number — side constant
-- @return table array of {tank, label, amount, capacity}, or nil + error
function HAL:getTankContents(side)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:getTankContents() — transposer not available"
    return nil, self._lastError
  end

  local transposer = component.transposer
  local tankCountOk, tankCount = pcall(transposer.getTankCount, transposer, side)
  if not tankCountOk or not tankCount then
    self._lastError = "HAL:getTankContents() — cannot get tank count"
    return nil, self._lastError
  end

  local contents = {}
  for tank = 1, tankCount do
    local fluidOk, fluid = pcall(transposer.getFluidInTank, transposer, side, tank)
    local levelOk, level = pcall(transposer.getTankLevel, transposer, side, tank)
    local capOk, capacity = pcall(transposer.getTankCapacity, transposer, side, tank)
    if not fluidOk then fluid = nil end
    if not levelOk then level = nil end
    if not capOk then capacity = nil end
    table.insert(contents, {
      tank     = tank,
      label    = (fluid and fluid.label) or nil,
      amount   = level or 0,
      capacity = capacity or 0,
      has      = fluid ~= nil,
    })
    os.sleep(0)
  end

  return contents
end

-- ===========================================================================
-- Maintenance state checking (checkMaintenanceState)
-- ===========================================================================

--- Perform a comprehensive maintenance check on a machine.
-- Queries the machine via pollHardware (from MachineNode) or directly,
-- then maps the results to a structured health report.
--
-- The check covers:
--   - Power status (EU starvation)
--   - Item jams (hasWork but not active)
--   - Ghost items in the ME interface
--   - Overall machine fault state
--
-- @param machineNode   MachineNode instance (from A2)
-- @return table with keys:
--   faulted      — boolean, true if any fault detected
--   faults       — table array of {code, label, description} for each fault
--   healthScore  — number 0–100 (100 = perfect)
--   powerOk      — boolean
--   progressOk   — boolean
--   ghostItems   — number of ghost items found (0 if clean)
--   recommendations — string array of suggested actions
function HAL:checkMaintenanceState(machineNode)
  self:clearError()

  local result = {
    faulted         = false,
    faults          = {},
    healthScore     = 100,
    powerOk         = true,
    progressOk      = true,
    ghostItems      = 0,
    recommendations = {},
  }

  if not machineNode then
    table.insert(result.faults, {
      code        = HAL.FAULT_DISCONNECTED,
      label       = "Machine Disconnected",
      description = "No machineNode reference provided to check",
    })
    result.faulted     = true
    result.healthScore = 0
    return result
  end

  -- Get capabilities for this machine type
  local capabilities = self:getCapabilities(machineNode.machineType)

  -- Phase 1: Poll hardware (protected with pcall for crash safety)
  local hwOk, hardwareState = pcall(machineNode.pollHardware, machineNode)
  if not hwOk or not hardwareState then
    hardwareState = {
      faulted = true,
      faultReason = tostring(hardwareState or "pollHardware crashed"),
      name = machineNode.machineType,
      eu = 0, euCapacity = 0,
      hasWork = false, active = false,
    }
  end
  local hasPowerCap = self:hasCapability(machineNode.machineType, HAL.CAP_POWER_EU)
                    or self:hasCapability(machineNode.machineType, HAL.CAP_POWER_STEAM)

  if hasPowerCap then
    if hardwareState.faulted then
      result.powerOk = false
      result.healthScore = result.healthScore - 30

      if hardwareState.euCapacity and hardwareState.euCapacity > 0
         and hardwareState.eu < (hardwareState.euCapacity * 0.05) then
        table.insert(result.faults, {
          code        = HAL.FAULT_POWER_STARVATION,
          label       = "Power Starvation",
          description = "EU reserve is critically low: "
                         .. tostring(hardwareState.eu) .. " / "
                         .. tostring(hardwareState.euCapacity),
        })
        table.insert(result.recommendations,
          "Check EU supply to machine; provide more power or reduce load")
      else
        -- Generic hardware fault
        table.insert(result.faults, {
          code        = HAL.FAULT_PROXY_ERROR,
          label       = "Hardware Error",
          description = hardwareState.faultReason or "Unknown hardware error",
        })
        table.insert(result.recommendations,
          "Inspect machine: " .. (hardwareState.name or "unknown"))
      end
    end
  end

  -- Phase 2: Check for item jams (hasWork but not active)
  if hardwareState.hasWork and not hardwareState.active then
    result.healthScore = result.healthScore - 25
    table.insert(result.faults, {
      code        = HAL.FAULT_ITEM_JAM,
      label       = "Item Jam Detected",
      description = "Machine has queued work but is not running — possible item jam or missing input",
    })
    table.insert(result.recommendations,
      "Check machine output bus for blockages; ensure input items/fluids are present")
  end

  -- Phase 3: Check for ghost items in the ME interface
  if component.isAvailable("transposer") then
    local transposer = component.transposer
    local ifaceSide = self:resolveSide("interface")
    if ifaceSide then
      local sizeOk, size = pcall(transposer.getInventorySize, transposer, ifaceSide)
      if sizeOk and size and size > 0 then
        local ghostCount = 0
        for slot = 1, size do
          local stackOk, stack = pcall(transposer.getStackInSlot, transposer, ifaceSide, slot)
          if stackOk and stack and stack.size and stack.size > 0 then
            ghostCount = ghostCount + stack.size
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

  -- Phase 4: Check machine status flag from MachineNode
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
  end

  -- Clamp health score
  if result.healthScore < 0 then
    result.healthScore = 0
  end
  result.faulted = #result.faults > 0

  return result
end

-- ===========================================================================
-- Database interaction helpers
-- ===========================================================================

--- Store an item ref from an inventory slot into the OC database.
-- Wraps transposer.store() for AE2 item reference management.
-- @param side       number — side of the inventory containing the reference item
-- @param slot       number — slot in that inventory
-- @param dbAddress  string — OC database component address
-- @param dbSlot     number — slot in the database to write to
-- @return boolean
function HAL:storeItemRef(side, slot, dbAddress, dbSlot)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:storeItemRef() — transposer not available"
    return false
  end

  if not component.isAvailable("database") and not self:getProxy(dbAddress) then
    self._lastError = "HAL:storeItemRef() — database component not available"
    return false
  end

  local ok, result = pcall(component.transposer.store, component.transposer,
    side, slot, dbAddress, dbSlot)
  if not ok then
    self._lastError = "HAL:storeItemRef() — store error: " .. tostring(result)
    return false
  end
  return result or false
end

--- Store a sample of each unique item in an inventory into the database.
-- Useful for discovering what items are present.
-- @param side       number — side of the inventory
-- @param dbAddress  string — database component address
-- @param dbStart    number — first database slot to use (default 1)
-- @return number of items stored
function HAL:snapshotInventoryToDB(side, dbAddress, dbStart)
  self:clearError()

  if not component.isAvailable("transposer") then
    self._lastError = "HAL:snapshotInventoryToDB() — transposer not available"
    return nil, self._lastError
  end

  local transposer = component.transposer
  local dbAddr = dbAddress
  -- If no dbAddress, try primary database
  if not dbAddr and component.isAvailable("database") then
    dbAddr = component.database.address
  end
  if not dbAddr then
    self._lastError = "HAL:snapshotInventoryToDB() — no database address available"
    return nil, self._lastError
  end

  local dbSlot = dbStart or 1
  local stored = 0
  local seen = {}  -- track by name to avoid duplicates

  local sizeOk, size = pcall(transposer.getInventorySize, transposer, side)
  if not sizeOk or not size then
    return 0
  end

  for slot = 1, size do
    local stackOk, stack = pcall(transposer.getStackInSlot, transposer, side, slot)
    if stackOk and stack and stack.size and stack.size > 0 and stack.name then
      if not seen[stack.name] then
        seen[stack.name] = true
        local storeOk, result = pcall(transposer.store, transposer, side, slot, dbAddr, dbSlot)
        if storeOk and result then
          dbSlot = dbSlot + 1
          stored = stored + 1
        end
      end
    end
    os.sleep(0)
  end

  return stored
end

-- ===========================================================================
-- Utility
-- ===========================================================================

--- Get a human-readable label for a capability flag set.
-- @param flags  number — bitmask
-- @return string
function HAL:capsToString(flags)
  local parts = {}
  if (flags & HAL.CAP_ITEM_INPUT) ~= 0 then table.insert(parts, "ITEM_INPUT") end
  if (flags & HAL.CAP_ITEM_OUTPUT) ~= 0 then table.insert(parts, "ITEM_OUTPUT") end
  if (flags & HAL.CAP_FLUID_INPUT) ~= 0 then table.insert(parts, "FLUID_INPUT") end
  if (flags & HAL.CAP_FLUID_OUTPUT) ~= 0 then table.insert(parts, "FLUID_OUTPUT") end
  if (flags & HAL.CAP_POWER_EU) ~= 0 then table.insert(parts, "POWER_EU") end
  if (flags & HAL.CAP_POWER_STEAM) ~= 0 then table.insert(parts, "POWER_STEAM") end
  if (flags & HAL.CAP_RECIPE_SELECT) ~= 0 then table.insert(parts, "RECIPE_SELECT") end
  if (flags & HAL.CAP_MAINTENANCE_HATCH) ~= 0 then table.insert(parts, "MAINTENANCE_HATCH") end
  if (flags & HAL.CAP_PARALLEL) ~= 0 then table.insert(parts, "PARALLEL") end
  if (flags & HAL.CAP_OVERCLOCK) ~= 0 then table.insert(parts, "OVERCLOCK") end
  return table.concat(parts, ", ")
end

--- Get a human-readable label for a fault code.
-- @param faultCode  number
-- @return string
function HAL:faultToString(faultCode)
  local labels = {
    [HAL.FAULT_NONE]             = "No Fault",
    [HAL.FAULT_POWER_STARVATION] = "Power Starvation",
    [HAL.FAULT_ITEM_JAM]         = "Item Jam",
    [HAL.FAULT_FLUID_ISSUE]      = "Fluid Issue",
    [HAL.FAULT_GHOST_ITEMS]      = "Ghost Items",
    [HAL.FAULT_NO_RECIPE]        = "No Recipe",
    [HAL.FAULT_OVERFLOW]         = "Overflow",
    [HAL.FAULT_DISCONNECTED]     = "Disconnected",
    [HAL.FAULT_PROXY_ERROR]      = "Proxy Error",
  }
  return labels[faultCode] or "Unknown (" .. tostring(faultCode) .. ")"
end

return HAL
