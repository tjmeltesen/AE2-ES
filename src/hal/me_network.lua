-- hal/me_network.lua -- ME controller, database, interface config
local HAL = require("src.hal.proxy")
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

--- Find the first craftable matching an ME-network item filter.
-- @param meControllerAddr string  CommonNetworkAPI component address
-- @param filter table  item filter accepted by getCraftables()
-- @return table|nil craftable, or nil + error
function HAL:getCraftable(meControllerAddr, filter)
  self:clearError()
  if type(filter) ~= "table" then
    return nil, "HAL:getCraftable() — filter must be a table"
  end

  local proxy = self:getProxy(meControllerAddr)
  if not proxy then return nil, self._lastError end
  if type(proxy.getCraftables) ~= "function" then
    return nil, "HAL:getCraftable() — component does not support getCraftables"
  end

  local ok, craftables = pcall(proxy.getCraftables, filter)
  if not ok or type(craftables) ~= "table" then
    return nil, "HAL:getCraftable() — getCraftables failed"
  end

  local craftable = craftables[1]
  if type(craftable) ~= "table" or type(craftable.request) ~= "function" then
    return nil, "HAL:getCraftable() — no craftable matches filter"
  end
  return craftable
end

--- Request a positive amount from a matching ME-network crafting pattern.
-- @param meControllerAddr string  CommonNetworkAPI component address
-- @param filter table  item filter accepted by getCraftables()
-- @param amount number  amount to craft
-- @return boolean, table|string  true + crafting job, or false + error
function HAL:requestCraft(meControllerAddr, filter, amount)
  if type(amount) ~= "number" or amount <= 0 then
    return false, "HAL:requestCraft() — amount must be positive"
  end

  local craftable, err = self:getCraftable(meControllerAddr, filter)
  if not craftable then return false, err end

  local ok, job = pcall(craftable.request, amount)
  if not ok or not job then
    return false, "HAL:requestCraft() — craft request failed"
  end
  return true, job
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

  local component = require("component")
  if not component then
    self._lastError = "HAL:storeItemRef() — component API unavailable"
    return false
  end
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

  local component = require("component")
  if not component then
    self._lastError = "HAL:snapshotInventoryToDB() — component API unavailable"
    return nil, self._lastError
  end
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
    [HAL.FAULT_PROXY_ERROR]       = "Proxy Error",
    [HAL.FAULT_NEEDS_MAINTENANCE]  = "Needs Maintenance",
    [HAL.FAULT_HAS_PROBLEMS]       = "Has Problems",
    [HAL.FAULT_INCOMPLETE_STRUCT]  = "Incomplete Structure",
    [HAL.FAULT_SENSOR_PARSE]       = "Sensor Data Warning",
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

return HAL
