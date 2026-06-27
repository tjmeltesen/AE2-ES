--[[
horizon-qa/json_writer.lua — Minimal JSON writer for test results
No external dependencies — pure Lua implementation.
]]--

local JsonWriter = {}

local function escape(s)
  s = tostring(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub('"', '\\"')
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return '"' .. s .. '"'
end

local function serialize(v, indent, depth)
  indent = indent or ""
  depth = depth or 0
  local t = type(v)

  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    if v ~= v then return "null" end  -- NaN
    if v == math.huge then return "null" end
    if v == -math.huge then return "null" end
    return string.format("%.17g", v)
  elseif t == "string" then
    return escape(v)
  elseif t == "table" then
    -- Check if array (sequential integer keys starting at 1)
    local isArray = true
    local maxIdx = 0
    for k in pairs(v) do
      if type(k) ~= "number" or math.floor(k) ~= k or k < 1 then
        isArray = false
        break
      end
      if k > maxIdx then maxIdx = k end
    end
    if isArray and maxIdx > 0 then
      -- verify no gaps
      local seen = {}
      for k in pairs(v) do seen[k] = true end
      for i = 1, maxIdx do
        if not seen[i] then isArray = false; break end
      end
    else
      isArray = false
    end

    local parts = {}
    local childIndent = indent .. "  "

    if isArray then
      for i = 1, maxIdx do
        local val = serialize(v[i], childIndent, depth + 1)
        table.insert(parts, childIndent .. val)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    else
      for k, val in pairs(v) do
        if type(k) == "string" and k:match("^[%a_][%w_]*$") then
          table.insert(parts, childIndent .. '"' .. k .. '": ' .. serialize(val, childIndent, depth + 1))
        else
          table.insert(parts, childIndent .. serialize(k, childIndent, depth + 1) .. ": " .. serialize(val, childIndent, depth + 1))
        end
      end
      table.sort(parts)  -- deterministic key order
      return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    end
  end
  return "null"
end

function JsonWriter.write(data, path)
  local content = serialize(data)
  local f, err = io.open(path, "w")
  if not f then
    return false, err
  end
  f:write(content)
  f:write("\n")
  f:close()
  return true
end

function JsonWriter.stringify(data)
  return serialize(data)
end

return JsonWriter
