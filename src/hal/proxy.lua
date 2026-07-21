-- hal/proxy.lua -- component proxy cache, capability flags, fault codes, constructor

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
HAL.FAULT_NEEDS_MAINTENANCE = 9   -- Maintenance hatch requires attention
HAL.FAULT_HAS_PROBLEMS      = 10  -- Machine reports "Has Problems"
HAL.FAULT_INCOMPLETE_STRUCT = 11  -- Multiblock structure incomplete
HAL.FAULT_SENSOR_PARSE      = 12  -- Sensor information could not be parsed

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
--   cacheTTL      — number, seconds before auto-refreshing a cached proxy (default 300)
--   capabilityMap — table mapping machine capability keys to flags. ConfigUI
--                    uses the manually configured machine address as the key.
-- @return HAL instance
function HAL:new(overrides)
  overrides = overrides or {}
  local self = setmetatable({}, HAL)

  -- Component proxy cache: address -> { proxy, timestamp }
  self._proxyCache   = {}
  self._cacheTTL     = overrides.cacheTTL or 300
  self._lastError    = nil

  -- Capability registry (merge defaults with setup-time registrations).
  -- ConfigUI supplies its persisted machineTypes map here; no discovery or
  -- component probe is performed while constructing HAL or during broker ticks.
  self._capMap = {}
  for mtype, flags in pairs(CAPABILITY_REGISTRY) do
    self:registerCapabilities(mtype, flags)
  end
  if overrides.capabilityMap then
    for mtype, flags in pairs(overrides.capabilityMap) do
      self:registerCapabilities(mtype, flags)
    end
  end

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
  local component = require("component")
  if not component or type(component.proxy) ~= "function" then
    self._lastError = "HAL:getProxy() — component API unavailable"
    return nil, self._lastError
  end
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

--- Register a machine capability key's flags during setup.
-- Runtime callers may use this for an explicit discovery refresh; broker ticks
-- must only query the already-registered map.
-- @param machineType  string (machine type or configured machine address)
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


return HAL
