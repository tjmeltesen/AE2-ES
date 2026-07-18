-- Versioned, atomic persistence for OpenComputers and standalone Lua.
-- No OpenComputers APIs are loaded until an instance performs I/O.

local Persistence = {}
Persistence.__index = Persistence

local function quote(value)
  return string.format("%q", value)
end

local function encode(value, seen)
  local kind = type(value)
  if kind == "nil" then return "nil" end
  if kind == "boolean" or kind == "number" then return tostring(value) end
  if kind == "string" then return quote(value) end
  if kind ~= "table" then error("cannot persist " .. kind) end

  seen = seen or {}
  if seen[value] then error("cannot persist cyclic table") end
  seen[value] = true

  local parts = { "{" }
  for key, item in pairs(value) do
    local keyKind = type(key)
    if keyKind ~= "string" and keyKind ~= "number" then
      seen[value] = nil
      error("cannot persist table key of type " .. keyKind)
    end
    parts[#parts + 1] = "[" .. encode(key, seen) .. "]=" .. encode(item, seen) .. ","
  end
  parts[#parts + 1] = "}"
  seen[value] = nil
  return table.concat(parts)
end

local function decode(content)
  local chunk, err
  if loadstring then
    chunk, err = loadstring("return " .. content, "persistence")
    if chunk and setfenv then setfenv(chunk, {}) end
  else
    chunk, err = load("return " .. content, "persistence", "t", {})
  end
  if not chunk then return nil, err end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= "table" then
    return nil, ok and "persisted data is not a table" or value
  end
  return value
end

local function validKey(key)
  return type(key) == "string" and key:match("^[%w%._%-]+$") ~= nil
end

function Persistence.new(options)
  options = options or {}
  return setmetatable({
    _directory = options.directory or "/home/.ae2es",
    _prefix = options.prefix or "state-",
    _open = options.open or io.open,
    _rename = options.rename or os.rename,
    _remove = options.remove or os.remove,
    _makeDirectory = options.makeDirectory,
  }, Persistence)
end

function Persistence:_path(key)
  assert(validKey(key), "persistence key must contain only letters, digits, '.', '_' or '-'")
  local separator = self._directory:sub(-1) == "/" and "" or "/"
  return self._directory .. separator .. self._prefix .. key .. ".lua"
end

function Persistence:_ensureDirectory()
  if self._directory == "." or self._directory == "" then return true end
  if self._makeDirectory then return self._makeDirectory(self._directory) end
  local ok, filesystem = pcall(require, "filesystem")
  if ok and filesystem and type(filesystem.makeDirectory) == "function" then
    return filesystem.makeDirectory(self._directory)
  end
  return true
end

function Persistence:_save(key, envelope)
  if type(envelope) ~= "table" or type(envelope.schemaVersion) ~= "number" or
      type(envelope.writtenAt) ~= "number" or type(envelope.payload) ~= "table" then
    return false, "invalid persistence envelope"
  end
  local directoryOk, directoryErr = pcall(self._ensureDirectory, self)
  if not directoryOk or directoryErr == false then
    return false, "could not create persistence directory"
  end

  local path = self:_path(key)
  local tempPath = path .. ".tmp"
  local ok, content = pcall(encode, envelope)
  if not ok then return false, content end

  local file, err = self._open(tempPath, "w")
  if not file then return false, err end
  local writeOk, writeErr = file:write(content)
  if file.flush then file:flush() end
  file:close()
  if not writeOk then
    self._remove(tempPath)
    return false, writeErr
  end
  local renamed, renameErr = self._rename(tempPath, path)
  if not renamed then
    self._remove(tempPath)
    return false, renameErr
  end
  return true
end

function Persistence:_removeFile(key)
  local path = self:_path(key)
  local removed, err = self._remove(path)
  if removed or err == nil then return true end
  return false, err
end

function Persistence:_load(key, validator)
  local path = self:_path(key)
  local file = self._open(path, "r")
  if not file then return nil, "not found" end
  local content = file:read("*a")
  file:close()
  local envelope, err = decode(content)
  if not envelope then
    self:_removeFile(key)
    return nil, "discarded corrupt persistence: " .. tostring(err)
  end
  if type(envelope.schemaVersion) ~= "number" or type(envelope.writtenAt) ~= "number" or
      type(envelope.payload) ~= "table" then
    self:_removeFile(key)
    return nil, "discarded invalid persistence envelope"
  end
  if validator then
    local ok, valid, reason = pcall(validator, envelope)
    if not ok or valid ~= true then
      self:_removeFile(key)
      return nil, "discarded incompatible persistence: " .. tostring(reason or valid)
    end
  end
  return envelope
end

local default = Persistence.new()

-- Support both the required module API (Persistence.save(key, envelope)) and
-- independently configured instances (store:save(key, envelope)).
function Persistence.save(selfOrKey, keyOrEnvelope, maybeEnvelope)
  if type(selfOrKey) == "table" and selfOrKey._directory then
    return selfOrKey:_save(keyOrEnvelope, maybeEnvelope)
  end
  return default:_save(selfOrKey, keyOrEnvelope)
end

function Persistence.load(selfOrKey, keyOrValidator, maybeValidator)
  if type(selfOrKey) == "table" and selfOrKey._directory then
    return selfOrKey:_load(keyOrValidator, maybeValidator)
  end
  return default:_load(selfOrKey, keyOrValidator)
end

function Persistence.remove(selfOrKey, maybeKey)
  if type(selfOrKey) == "table" and selfOrKey._directory then
    return selfOrKey:_removeFile(maybeKey)
  end
  return default:_removeFile(selfOrKey)
end

return Persistence
