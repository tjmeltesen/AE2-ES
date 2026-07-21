-- hal/transfer.lua -- transfer utilities, slot checking, redstone, diagnostics
local HAL = require("src.hal.proxy")
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
    [HAL.FAULT_PROXY_ERROR]       = "Proxy Error",
    [HAL.FAULT_NEEDS_MAINTENANCE]  = "Needs Maintenance",
    [HAL.FAULT_HAS_PROBLEMS]       = "Has Problems",
    [HAL.FAULT_INCOMPLETE_STRUCT]  = "Incomplete Structure",
    [HAL.FAULT_SENSOR_PARSE]       = "Sensor Data Warning",
  }
  return labels[faultCode] or "Unknown (" .. tostring(faultCode) .. ")"
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
  local ok, component = pcall(require, "component")
  if not ok then
    self._lastError = "HAL:checkSlotCount() — component API unavailable"
    return nil, self._lastError
  end
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

  local ok, sides = pcall(require, "sides")
  if not ok then
    self._lastError = "HAL:mapSides() — sides API unavailable"
    return {}
  end
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

---Sets the strength of the redstone signal to emit on a specific side.
---@param side integer # The side to set the output on.
---@param value integer # The value to output on the specified side.
---@param redstoneLockAddress string # The address of the redstone lock to set the output on.
---@return boolean, error string
function HAL:setRedstoneLock(redstoneLockAddress, side, value)
  self:clearError()
  local redstoneLock = self:getProxy(redstoneLockAddress)
  if not redstoneLock then
    self._lastError = "HAL:setRedstoneLock() — redstoneLock not available"
    return false, self._lastError
  end
  
  local ok, err = pcall(redstoneLock.setOutput, side, value)
  if not ok then
    self._lastError = "HAL:setRedstoneLock() — redstoneLock.setOutput failed: " .. tostring(err)
    return false, self._lastError
  end
  return true, nil
end

---Sets the strength of the redstone signal to emit on a specific side.
--- From High to Low
---@param redstoneLockAddress string # The address of the redstone lock to set the output on.
---@param side integer # The side to set the output on.
---@param pulseDuration number # The time in seconds a single pulse will last.
---@return boolean
function HAL:pulseRedstoneLock(redstoneLockAddress, side, pulseDuration)
  self:clearError()

  local ok, err = self:setRedstoneLock(redstoneLockAddress, side, 15)
  if not ok then
    self._lastError = "HAL:pulseRedstoneLock() — redstoneLock.setOutput failed: " .. tostring(err)
    return false, self._lastError
  end
  os.sleep(pulseDuration)
  ok, err = self:setRedstoneLock(redstoneLockAddress, side, 0)
  if not ok then
    self._lastError = "HAL:pulseRedstoneLock() — redstoneLock.setOutput failed: " .. tostring(err)
    return false, self._lastError
  end
  return true, nil
end


return HAL
