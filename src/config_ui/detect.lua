-- config_ui/detect.lua -- component detection
local ConfigUI = require("src.config_ui.terminal")
-- ===========================================================================
-- Component detection
-- ===========================================================================

--- Detect available OC components on the system.
-- Scans for modem, transposer, redstone, adapters, ME controllers,
-- ME interfaces, and other known component types.
-- @return table { components = {...}, errors = {...} }
function ConfigUI:detectComponents()
  if self._detectedComponents then
    return self._detectedComponents
  end

  local component = self._component or require("component")
  local result = {
    components = {},
    errors = {},
    modem = nil,
    transposer = nil,
    redstone = nil,
    database = nil,
    meController = nil,
    meInterfaces = {},
    gtMachines = {},
    misc = {},
  }

  if not component then
    table.insert(result.errors, "OC component library not available")
    self._detectedComponents = result
    return result
  end

  -- Enumerate all components
  local ok, iter = pcall(component.list)
  if not ok then
    table.insert(result.errors, "component.list() failed")
    self._detectedComponents = result
    return result
  end

  for address, name in iter do
    local entry = { address = address, type = name }
    table.insert(result.components, entry)

    if name == "modem" then
      result.modem = entry
    elseif name == "transposer" then
      result.transposer = entry
    elseif name == "redstone" then
      result.redstone = entry
    elseif name == "database" then
      result.database = entry
    elseif name == "me_controller" then
      result.meController = entry
    elseif name == "me_interface" then
      table.insert(result.meInterfaces, entry)
    elseif name:find("gt_machine") or name:find("^gt_") then
      table.insert(result.gtMachines, entry)
    else
      table.insert(result.misc, entry)
    end
  end

  -- Sort machines and interfaces by address for deterministic order
  local function sortByAddr(a, b)
    return a.address < b.address
  end
  table.sort(result.gtMachines, sortByAddr)
  table.sort(result.meInterfaces, sortByAddr)

  self._detectedComponents = result
  return result
end

--- Detect a specific component by type.
-- @param typeName  string  e.g. "modem", "transposer"
-- @return table or nil  { address, type }
function ConfigUI:findComponent(typeName)
  local detected = self:detectComponents()
  for _, entry in ipairs(detected.components) do
    if entry.type == typeName then
      return entry
    end
  end
  return nil
end

--- Test connectivity to a component address.
-- Attempts to create a proxy and query basic info.
-- @param address  string  component address
-- @param compType string  optional expected type
-- @return boolean, string  success, diagnostic message
function ConfigUI:testComponent(address, compType)
  if not address or address == "" then
    return false, "No address provided"
  end

  local component = self._component or require("component")
  if not component then
    return false, "OC component library not available"
  end

  local ok, proxy = pcall(component.proxy, address)
  if not ok or not proxy then
    return false, "component.proxy() failed for this address. Check that the address is correct and the block is still placed."
  end

  -- Try to get basic type info
  local proxyType = ""
  local typeOk, typeVal = pcall(function() return proxy.type end)
  if typeOk and typeVal then
    proxyType = tostring(typeVal)
  end

  local addrOk, addrVal = pcall(function() return proxy.address end)
  local proxyAddr = ""
  if addrOk and addrVal then
    proxyAddr = tostring(addrVal)
  end

  if compType and proxyType ~= compType then
    return false, string.format("Expected type '%s' but proxy reports type '%s'", compType, proxyType)
  end

  -- Additional validation by type
  if compType == "modem" or proxyType == "modem" then
    local openOk, _ = pcall(function() return proxy.open(math.random(60000, 65535)) end)
    if not openOk then
      return false, "Modem proxy exists but open() failed. Check that the modem is installed and the computer has a network card."
    end
    pcall(function() return proxy.close(123) end)
    return true, "Modem connected and responding"
  end

  if proxyAddr and #proxyAddr > 0 then
    return true, string.format("Proxy created: type=%s, address=%s", proxyType, proxyAddr)
  end

  return true, "Proxy created successfully"
end


return ConfigUI
