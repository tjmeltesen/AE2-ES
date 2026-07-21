-- hal/inventory.lua -- inventory + fluid transfer operations
local HAL = require("src.hal.proxy")
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
  local component = require("component")
  if not component then
    self._lastError = "HAL:isSlotEmpty() — component API unavailable"
    return nil, self._lastError
  end
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

return HAL
