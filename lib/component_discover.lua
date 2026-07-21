--[[
component_discover.lua — setup-time OpenComputers component discovery.

The module deliberately receives the component API from its caller so importing
it never touches OpenComputers globals. Discovery is intended for configuration
and explicit refreshes, never broker tick processing.
]]--

local ComponentDiscover = {}

local function componentEntries(componentApi, predicate)
  local entries = {}
  if type(componentApi) ~= "table" or type(componentApi.list) ~= "function" then
    return entries
  end

  local ok, iterator = pcall(componentApi.list)
  if not ok or type(iterator) ~= "function" then
    return entries
  end

  for address, componentType in iterator do
    if type(address) == "string" and type(componentType) == "string"
        and predicate(componentType) then
      table.insert(entries, { address = address, type = componentType })
    end
  end

  table.sort(entries, function(a, b)
    return a.address < b.address
  end)
  return entries
end

--- Return component entries of an exact OC component type.
-- @param componentApi table OpenComputers component API
-- @param typeName string component type to find
-- @return table array of { address, type }
function ComponentDiscover.discoverByType(componentApi, typeName)
  if type(typeName) ~= "string" or typeName == "" then
    return {}
  end
  return componentEntries(componentApi, function(componentType)
    return componentType == typeName
  end)
end

--- Return GT machine adapter entries.
-- GTNH adapters commonly report "gt_machine"; accept other "gt_" types for
-- compatible addon machines, matching the legacy ConfigUI detection behavior.
-- @param componentApi table OpenComputers component API
-- @return table array of { address, type }
function ComponentDiscover.discoverGtMachines(componentApi)
  return componentEntries(componentApi, function(componentType)
    return componentType == "gt_machine" or componentType:match("^gt_") ~= nil
  end)
end

--- Return transposer entries usable for one-time storage-side inspection.
-- The caller owns any inventory probing; this helper intentionally performs
-- enumeration only so it cannot introduce I/O into a broker hot loop.
-- @param componentApi table OpenComputers component API
-- @return table array of { address, type }
function ComponentDiscover.discoverTransposerStorage(componentApi)
  return ComponentDiscover.discoverByType(componentApi, "transposer")
end

return ComponentDiscover
