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
HAL.CAP_PROFILE_BASIC     = HAL.CAP_ITEM_INPUT + HAL.CAP_ITEM_OUTPUT + HAL.CAP_POWER_EU
HAL.CAP_PROFILE_FLUID     = HAL.CAP_ITEM_INPUT + HAL.CAP_ITEM_OUTPUT + HAL.CAP_FLUID_INPUT + HAL.CAP_FLUID_OUTPUT + HAL.CAP_POWER_EU
HAL.CAP_PROFILE_STEAM     = HAL.CAP_ITEM_INPUT + HAL.CAP_ITEM_OUTPUT + HAL.CAP_POWER_STEAM
HAL.CAP_PROFILE_MULTI     = HAL.CAP_ITEM_INPUT + HAL.CAP_ITEM_OUTPUT + HAL.CAP_FLUID_INPUT + HAL.CAP_FLUID_OUTPUT + HAL.CAP_POWER_EU + HAL.CAP_MAINTENANCE_HATCH

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
  transposerInput  = sides.north,  -- Transposer pulls from drawer here
  transposerOutput = sides.south,  -- Transposer drops into machine input bus
  transposerReturn = sides.east,   -- Transposer pulls machine output → return chest
  dualInterface = sides.north,   -- Transposer side facing Dual Interface
  returnChest   = sides.east,    -- Transposer side facing Return Chest
  fluidExport   = sides.north,   -- Interface side for fluid conduit
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
  return (caps / flag) % 2 >= 1  -- bit test (Lua 5.2 compat: no bitwise &)
end

-- ===========================================================================
-- Side resolution
-- ===========================================================================

--- Resolve a logical role name to a side constant.
-- @param role  string — one of "inputBus", "inputHatch",
--              "itemBuffer", "fluidBuffer", "transposerInput", "transposerOutput",
--              "transposerReturn"
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
-- @param transposerAddress string — transposer component address
-- @param toSide    number — destination side constant
-- @param count     number|nil — max items to transfer (nil = all)
-- @param fromSlot  number|nil — source slot (nil = any)
-- @param toSlot    number|nil — destination slot (nil = any)
-- @return number of items transferred, or nil + errorMessage on failure
function HAL:performInventoryTransfer(transposerAddress, fromSide, toSide, count, fromSlot, toSlot)
  self:clearError()

  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:performInventoryTransfer() — transposer not available"
    return nil, self._lastError
  end
  local ok, result = pcall(transposer.transferItem, fromSide, toSide, count, fromSlot, toSlot)

  if not ok then
    self._lastError = "HAL:performInventoryTransfer() — transposer error: " .. tostring(result)
    return nil, self._lastError
  end

  os.sleep(0)
  return result
end

--- Transfer all items from one inventory to another using the getAllStacks iterator. (WORKING)
-- @param fromSide  number — source side constant
-- @param transposerAddress string — transposer component address
-- @param toSide    number — destination side constant
-- @return number of total items transferred, or nil + error
function HAL:drainInventory(transposerAddress, fromSide, toSide)
  self:clearError()

  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:drainInventory() — transposer not available"
    return nil, self._lastError
  end
  local total = 0

  -- 1. Grab the iterator (Takes only 1 tick for the entire inventory)
  local ok, stackSlot = pcall(transposer.getAllStacks, fromSide)
  if not ok then
    self._lastError = "HAL:drainInventory() — getAllStacks failed"
    return nil, self._lastError
  end
  -- If it didn't return a function, exit
  local stacks = stackSlot.getAll()

  -- 2. Slots are 1-indexed, so we start our manual counter at 1
  for slotIndex, stack in pairs(stacks) do
    -- OpenComputers usually uses 1-based indexing for slots in transferItem
    -- We assume the index provided by the array aligns with the slot
    local okMove, moved = pcall(transposer.transferItem, fromSide, toSide, stack.size, slotIndex)
    
    if okMove and moved then
      total = total + moved
    end
    os.sleep(0)
  end

  return total
end

--- Get a snapshot of all items in an inventory.
-- @param side  number — side constant
-- @param transposerAddress string — transposer component address
-- @return table array of {slot, label, size, maxSize, hasNBT}, or nil + error
function HAL:getInventoryContents(transposerAddress, side)
  self:clearError()
  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:getInventoryContents() — transposer not available"
    return nil, self._lastError
  end
  local sizeOk, size = pcall(transposer.getInventorySize, side)
  if not sizeOk or not size then
    self._lastError = "HAL:getInventoryContents() — cannot get inventory size"
    return nil, self._lastError
  end

  local contents = {}
  for slot = 1, size do
    local stackOk, stack = pcall(transposer.getStackInSlot, side, slot)
    if stackOk and stack then
      -- getStackInSlot may not include .size on GTNH — use getSlotStackSize fallback
      local sz = stack.size
      if not sz or sz == 0 then
        local cntOk, cnt = pcall(transposer.getSlotStackSize, side, slot)
        if cntOk and type(cnt) == "number" then sz = cnt end
      end
      table.insert(contents, {
        slot    = slot,
        label   = stack.label,
        size    = sz,
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

--- Get a snapshot of all fluids in tanks on a given side.
-- @param transposerAddress string — transposer component address
-- @param side  number — side constant
-- @return table array of {tank, label, amount, capacity}, or nil + error
function HAL:getTankContents(transposerAddress, side)
  self:clearError()

  local transposer = self:getProxy(transposerAddress)
  if not transposer then
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
-- ME Controller — central buffer (replaces inventory_controller + tank_controller)
-- ===========================================================================

--- Query the ME Controller/Interface (CommonNetworkAPI) for all items and fluids.
-- Items with a fluidDrop sub-table are split into the fluids array and mapped
-- to the fluid pipeline shape. All other items stay in items.
-- Also calls getFluidsInNetwork() for pure fluids (when discretizer is absent).
-- @param meControllerAddr  string  OC ME Controller/Interface address
-- @return table  { items = {...}, fluids = {...} }
-- @return nil, string  on error
function HAL:getMEContents(meControllerAddr)
  self:clearError()
  local proxy = self:getProxy(meControllerAddr)
  if not proxy then return nil, self._lastError end

  local items = {}
  local fluids = {}
  local seenFluids = {}  -- dedupe by name when both APIs return same fluid

  -- 1) getItemsInNetwork — items + discretized fluid drops
  local ok, allItems = pcall(proxy.getItemsInNetwork)
  if ok and type(allItems) == "table" then
    for _, entry in ipairs(allItems) do
      if type(entry) == "table" then
        if entry.fluidDrop and type(entry.fluidDrop) == "table" then
          -- Discretized fluid → map to fluid pipeline shape.
          -- entry.name is the drop-item ID (e.g. "ae2fc:fluid_drop") needed
          -- for database.set(); entry.fluidDrop.name/label is the actual fluid identity.
          if not seenFluids[entry.fluidDrop.name or entry.fluidDrop.label] then
            table.insert(fluids, {
              name   = entry.name or entry.fluidDrop.name or "unknown",
              label  = entry.fluidDrop.label or entry.fluidDrop.name or "unknown",
              amount = entry.size or entry.fluidDrop.amount or 0,
              hasTag = entry.hasTag or false,
              tag    = entry.tag or nil,
            })
            seenFluids[entry.fluidDrop.name or entry.fluidDrop.label] = true
          end
        else
          -- Regular item
          table.insert(items, {
            name   = entry.name or "unknown",
            label  = entry.label or "unknown",
            size   = entry.size or 0,
            damage = entry.damage or 0,
            nbt    = entry.tag or nil,
          })
        end
      end
    end
  end

  -- 2) getFluidsInNetwork — pure fluids (works even without discretizer)
  local flOk, allFluids = pcall(proxy.getFluidsInNetwork)
  if flOk and type(allFluids) == "table" then
    for _, entry in ipairs(allFluids) do
      if type(entry) == "table" and entry.label then
        if not seenFluids[entry.name or entry.label] then
          table.insert(fluids, {
            name   = entry.name or entry.label or "unknown",
            label  = entry.label or entry.name or "unknown",
            amount = entry.amount or 0,
            hasTag = entry.hasTag or false,
            tag    = entry.tag or nil,
          })
          seenFluids[entry.name or entry.label] = true
        end
      end
    end
  end

  return { items = items, fluids = fluids }
end

-- ===========================================================================
-- Maintenance state checking (checkMaintenanceState)
-- ===========================================================================

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
-- Polls hardware via pollMachineHardware, then maps results to a structured
-- health report.
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
function HAL:checkMaintenanceState(machineNode, transposerAddr, ifaceSide)
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

  -- Phase 1: Poll hardware through HAL (not MachineNode)
  local hardwareState = self:pollMachineHardware(machineNode)
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
    if stackOk and stack and stack.name then
      local sz = stack.size
      if not sz or sz <= 0 then
        local cntOk, cnt = pcall(transposer.getSlotStackSize, transposer, side, slot)
        if cntOk and type(cnt) == "number" then sz = cnt end
      end
      if sz and sz > 0 then
      if not seen[stack.name] then
        seen[stack.name] = true
        local storeOk, result = pcall(transposer.store, transposer, side, slot, dbAddr, dbSlot)
        if storeOk and result then
          dbSlot = dbSlot + 1
          stored = stored + 1
        end
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
  if (flags / HAL.CAP_ITEM_INPUT) % 2 >= 1 then table.insert(parts, "ITEM_INPUT") end
  if (flags / HAL.CAP_ITEM_OUTPUT) % 2 >= 1 then table.insert(parts, "ITEM_OUTPUT") end
  if (flags / HAL.CAP_FLUID_INPUT) % 2 >= 1 then table.insert(parts, "FLUID_INPUT") end
  if (flags / HAL.CAP_FLUID_OUTPUT) % 2 >= 1 then table.insert(parts, "FLUID_OUTPUT") end
  if (flags / HAL.CAP_POWER_EU) % 2 >= 1 then table.insert(parts, "POWER_EU") end
  if (flags / HAL.CAP_POWER_STEAM) % 2 >= 1 then table.insert(parts, "POWER_STEAM") end
  if (flags / HAL.CAP_RECIPE_SELECT) % 2 >= 1 then table.insert(parts, "RECIPE_SELECT") end
  if (flags / HAL.CAP_MAINTENANCE_HATCH) % 2 >= 1 then table.insert(parts, "MAINTENANCE_HATCH") end
  if (flags / HAL.CAP_PARALLEL) % 2 >= 1 then table.insert(parts, "PARALLEL") end
  if (flags / HAL.CAP_OVERCLOCK) % 2 >= 1 then table.insert(parts, "OVERCLOCK") end
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

-- ===========================================================================
-- Database operations (JIT: store buffer refs as AE2-compatible entries)
-- Database has max 9 slots -- caller must manage slot allocation.
-- ===========================================================================


--- [DEPRECATED] Store an item/fluid reference using the old OC Database API.
-- Use HAL:storeNetworkEntry() instead — CommonNetworkAPI.store() handles
-- zlib-BNBT → JSON NBT encoding correctly that manual db.set() does not.
-- Kept for backward compat; all production callers should migrate.
-- @param dbAddress  string   OC Database component address
-- @param slot       number   1-indexed slot (1-9)
-- @param name       string   Unlocalized item/fluid name (id param to db.set)
-- @param label      string   Localized item/fluid label (for logging, not passed to DB)
-- @param damage     number   Item damage value (0 for fluids)
-- @param nbt        string|nil  NBT data in JSON format (nil if none)
-- @return boolean
function HAL:storeDatabaseEntry(dbAddress, slot, name, label, damage, nbt)
  self:clearError()

  local db = self:getProxy(dbAddress)
  if not db then
    return false, self._lastError
  end

  local ok, result = pcall(db.set, slot, name, damage, nbt)
  if not ok then
    self._lastError = "storeDatabaseEntry: db.set failed at slot " .. slot
      .. " — " .. tostring(result)
    return false, self._lastError
  end

  if result == false then
    self._lastError = "storeDatabaseEntry: db.set reported failure at slot " .. slot
    return false, self._lastError
  end

  return true
end

--- Store a single matching network entry into the database using the native
-- CommonNetworkAPI.store() method. Handles NBT encoding correctly (zlib BNBT
-- → JSON) which manual db.set() does not. Used for both items and fluid drops.
-- Items: filter = { name = "mod:item", damage = 0 }
-- Fluids: filter = { label = "drop of <fluid>" }
-- @param meAddr     string   ME Controller/Interface address
-- @param filter     table    Filter matching the item/fluid to store
-- @param dbAddress  string   OC Database address
-- @param slot       number   1-indexed slot
-- @return boolean
function HAL:storeNetworkEntry(meAddr, filter, dbAddress, slot)
  self:clearError()
  local proxy = self:getProxy(meAddr)
  if not proxy then return false, self._lastError end

  local ok, result = pcall(proxy.store, filter, dbAddress, slot, 1)
  if not ok then
    self._lastError = "storeNetworkEntry: store() failed: " .. tostring(result)
    return false, self._lastError
  end
  if result == false then
    self._lastError = "storeNetworkEntry: store() reported failure at slot " .. slot
    return false, self._lastError
  end
  return true
end

--- Clear a single Database slot.
-- Uses db.clear() — CommonNetworkAPI has no clear method, so this stays
-- on the old OC Database API by necessity.
-- @param dbAddress  string
-- @param slot       number   1-indexed
-- @return boolean
function HAL:clearDatabaseSlot(dbAddress, slot)
  self:clearError()
  local db = self:getProxy(dbAddress)
  if not db then return false, self._lastError end
  local ok, err = pcall(db.clear, slot)
  if not ok then
    self._lastError = "HAL:clearDatabaseSlot() — db.clear[" .. slot .. "] failed: " .. tostring(err)
    return false, self._lastError
  end
  return true
end

-- ===========================================================================
-- ME Interface configuration
-- ===========================================================================

--- Configure an ME Interface slot to stock items from a Database reference.
-- @param ifaceAddress  string   ME Interface component address
-- @param slot          number   1-indexed config slot on interface (1-9)
-- @param dbAddress     string   Database component address
-- @param dbSlot        number   Database slot holding item reference
-- @param count         number   How many items to stock
-- @return boolean
function HAL:configureInterfaceStocking(ifaceAddress, slot, dbAddress, dbSlot, count)
  self:clearError()
  local iface = self:getProxy(ifaceAddress)
  if not iface then return false, self._lastError end
  local ok, err = pcall(iface.setInterfaceConfiguration, slot, dbAddress, dbSlot, count)
  if not ok then
    self._lastError = "HAL:configureInterfaceStocking() — failed: " .. tostring(err)
    return false, self._lastError
  end
  return true
end

--- Clear an ME Interface config slot.
-- @param ifaceAddress  string
-- @param slot          number   1-indexed
-- @return boolean
function HAL:clearInterfaceSlot(ifaceAddress, slot)
  self:clearError()
  local iface = self:getProxy(ifaceAddress)
  if not iface then return false, self._lastError end
  local ok, err = pcall(iface.setInterfaceConfiguration, slot)
  if not ok then
    self._lastError = "HAL:clearInterfaceSlot() — failed: " .. tostring(err)
    return false, self._lastError
  end
  return true
end

--- Configure fluid export on an ME Interface side.
-- @param ifaceAddress  string
-- @param side          number   Side constant for fluid export
-- @param dbAddress     string   Database component address
-- @param dbSlot        number   Database slot holding fluid reference
-- @return boolean
function HAL:configureFluidExport(ifaceAddress, side, dbAddress, dbSlot)
  self:clearError()
  local iface = self:getProxy(ifaceAddress)
  if not iface then return false, self._lastError end
  local ok, result = pcall(iface.setFluidInterfaceConfiguration, side, dbAddress, dbSlot)
  
  if not ok then
    self._lastError = "HAL:configureFluidExport() — pcall failed: " .. tostring(result)
    return false, self._lastError
  end
  if result == false then
    self._lastError = "HAL:configureFluidExport() — iface.setFluidInterfaceConfiguration reported failure at side " .. side
    return false, self._lastError
  end
  return true
end

--- Clear fluid export config on an interface side.
-- @param ifaceAddress  string
-- @param side          number
-- @return boolean
function HAL:clearFluidExport(ifaceAddress, side)
  self:clearError()
  local iface = self:getProxy(ifaceAddress)
  if not iface then return false, self._lastError end
  local ok, err = pcall(iface.setFluidInterfaceConfiguration, side)
  if not ok then
    self._lastError = "HAL:clearFluidExport() — failed: " .. tostring(err)
    return false, self._lastError
  end
  return true
end

-- ===========================================================================
-- Inventory inspection
-- ===========================================================================

--- Check how many items are in an inventory slot via transposer.
-- Used to verify AE2 has stocked the interface before transferring.
-- @param side  number   Transposer side facing the inventory
-- @param slot  number   1-indexed slot
-- @return number  stack size (0 if empty), or nil + error
function HAL:checkSlotCount(side, slot)
  self:clearError()
  if not component.isAvailable("transposer") then
    self._lastError = "HAL:checkSlotCount() — transposer not available"
    return nil, self._lastError
  end
  local xp = component.transposer
  local ok, stack = pcall(xp.getStackInSlot, side, slot)
  if not ok then
    self._lastError = "HAL:checkSlotCount() — getStackInSlot failed: " .. tostring(stack)
    return nil, self._lastError
  end
  if not stack then return 0 end
  if stack.size and stack.size > 0 then return stack.size end
  -- GTNH quirk: .size may be absent; try getSlotStackSize
  local cntOk, cnt = pcall(xp.getSlotStackSize, side, slot)
  if cntOk and type(cnt) == "number" then return cnt end
  return 0
end


--- Check if an ME Interface has items stocked in its configuration slots.
-- Uses getInterfaceConfiguration rather than transposer slot inspection.
-- @param ifaceAddress  string   ME Interface component address
-- @param slotCount     number   How many config slots to check (1-9)
-- @return boolean stocked, or nil + error
function HAL:checkInterfaceStocked(ifaceAddress, slotCount)
  self:clearError()
  local iface = self:getProxy(ifaceAddress)
  if not iface then
    self._lastError = "HAL:checkInterfaceStocked() — getProxy failed: " .. tostring(ifaceAddress)
    return nil, self._lastError
  end

  for i = 1, slotCount do
    local ok, cfg = pcall(iface.getInterfaceConfiguration, i)
    if not ok then
      self._lastError = "HAL:checkInterfaceStocked() — getInterfaceConfiguration failed: " .. tostring(cfg)
    elseif cfg then
      return true
    end
  end

  return false
end

--- Maps all valid inventories adjacent to the transposer.
-- @param transposerAddress string — transposer component address
-- @return table mapping side constants to {name, slots}
function HAL:mapSides(transposerAddress)
  self:clearError()
  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:mapSides() — transposer not available"
    return {}
  end

  local sides = require("sides")
  local result = {}

  local validSides = {sides.north, sides.south, sides.east, sides.west, sides.up, sides.down}
  
  for _, side in ipairs(validSides) do
    local okSize, size = pcall(transposer.getInventorySize, side)
    
    if okSize and size and size > 0 then
      local okName, name = pcall(transposer.getInventoryName, side)
      result[side] = {
        name = (okName and name) or "unknown",
        slots = size,
      }
    end
    os.sleep(0)
  end
  
  return result
end

--- Transfer exactly ONE item by its label (Fast Iterator Method)
-- @param fromSide  number — source side constant
-- @param transposerAddress string — transposer component address
-- @param toSide    number — destination side constant
-- @param label     string — exact label to match
-- @return number of items moved (1 for success, 0 for out of stock)
function HAL:transferOneByLabel(transposerAddress, fromSide, toSide, label)
  self:clearError()
  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:transferOneByLabel() — transposer not available"
    return 0
  end
  local ok, iterator = pcall(transposer.getAllStacks, fromSide)
  if not ok or type(iterator) ~= "function" then return 0 end

  local currentSlot = 1 
  for stack in iterator do
    if type(stack) == "table" and stack.size and stack.size > 0 and stack.label == label then
      local okMove, moved = pcall(transposer.transferItem, fromSide, toSide, 1, currentSlot, currentSlot)
      return (okMove and moved) or 0
    end
    currentSlot = currentSlot + 1
    os.sleep(0)
  end
  
  return 0 
end

--- Transfer a specific amount with built-in retry delays for slow AE2 restocks
-- @param fromSide  number
-- @param transposerAddress string — transposer component address
-- @param toSide    number
-- @param amount    number — total target amount to move
-- @param fromSlot  number
-- @param toSlot    number (optional)
-- @param maxTries  number (optional, defaults to 10)
-- @return number of items actually moved
function HAL:transferWithRetry(transposerAddress, fromSide, toSide, amount, fromSlot, toSlot, maxTries)
  self:clearError()

  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:transferWithRetry() — transposer not available"
    return 0
  end
  maxTries = maxTries or 10
  toSlot = toSlot or fromSlot
  local remaining = amount
  
  for attempt = 1, maxTries do
    local okMove, moved = pcall(transposer.transferItem, fromSide, toSide, remaining, fromSlot, toSlot)
    
    if okMove and moved then
      remaining = remaining - moved
    end
    
    if remaining <= 0 then 
      return amount 
    end
    
    if not moved or moved == 0 then
      -- Source is empty or starving, sleep to allow AE2/network to push more items
      os.sleep(0.5)
    end
  end
  
  return amount - remaining
end

--- Return leftover items from machine output back to the interface/network
-- @param returnSide number — side facing machine output
-- @param pullSide   number — side facing ME Interface / Dual Interface
-- @param transposerAddress string — transposer component address
-- @param slotsArray table  — array of slot numbers to clear
function HAL:returnLeftovers(transposerAddress, returnSide, pullSide, slotsArray)
  self:clearError()
  local transposer = self:getProxy(transposerAddress)
  if not transposer then
    self._lastError = "HAL:returnLeftovers() — transposer not available"
    return false
  end
  
  for _, slot in ipairs(slotsArray) do
    pcall(transposer.transferItem, returnSide, pullSide, 64, slot, slot)
    os.sleep(0)
  end
  
  return true
end

return HAL
