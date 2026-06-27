-- TelemetryPayload module
-- Standardized outbound envelope from Exec Broker to Supervisor.
-- Flat structure (Lua serializable): brokerId, timestamp, queueLength,
-- hardwareMatrix, alerts.
-- Methods: build, serialize, deserialize, transmit, validate

-- Mock OC serialization library (standalone-safe)
local serialization = {}
do
  -- Minimal Lua serializer for standalone testing.
  -- In OC, this is provided by the `serialization` library.
  local function serialize_value(v, depth)
    if depth and depth > 20 then return "nil" end
    local t = type(v)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then return string.format("%.17g", v)
    elseif t == "string" then return string.format("%q", v)
    elseif t == "table" then
      local out = {}
      table.insert(out, "{")
      local first = true
      for k, val in pairs(v) do
        if not first then table.insert(out, ",") end
        first = false
        local d = (depth or 0) + 1
        table.insert(out, "[" .. serialize_value(k, d) .. "]=" .. serialize_value(val, d))
      end
      table.insert(out, "}")
      return table.concat(out)
    else return "nil" end
  end

  function serialization.serialize(v)
    return serialize_value(v, 0)
  end

  function serialization.unserialize(s)
    -- Use load() for safe deserialization in Lua
    if not s or s == "" then return nil end
    local f, err = load("return " .. s, "deserialize", "t", {})
    if not f then return nil, err end
    return pcall(f) and f() or nil
  end
end

local TelemetryPayload = {}
TelemetryPayload.__index = TelemetryPayload

-- Schema version for compatibility checking
TelemetryPayload.SCHEMA_VERSION = 1

-- Required fields in every payload
local REQUIRED_FIELDS = {
  "brokerId",
  "timestamp",
  "queueLength",
  "hardwareMatrix",
  "alerts",
}

--- Build a TelemetryPayload from broker state
--- @param params table {brokerId, queueLength, hardwareMatrix, alerts}
--- @return TelemetryPayload
function TelemetryPayload.build(params)
  local self = setmetatable({}, TelemetryPayload)

  -- Validate required params
  if not params or not params.brokerId then
    return nil, "missing brokerId"
  end

  self.brokerId = params.brokerId
  self.schemaVersion = TelemetryPayload.SCHEMA_VERSION
  self.timestamp = params.timestamp or (os.epoch and os.epoch() or os.time())
  self.queueLength = params.queueLength or 0
  self.hardwareMatrix = params.hardwareMatrix or {}
  self.alerts = params.alerts or {}

  -- Validate types
  if type(self.brokerId) ~= "string" then
    return nil, "brokerId must be a string"
  end
  if type(self.queueLength) ~= "number" then
    return nil, "queueLength must be a number"
  end
  if type(self.hardwareMatrix) ~= "table" then
    return nil, "hardwareMatrix must be a table"
  end
  if type(self.alerts) ~= "table" then
    return nil, "alerts must be a table"
  end

  return self
end

--- Serialize to a modem-safe string
--- @return string serialized payload
function TelemetryPayload:serialize()
  local flat = {
    brokerId = self.brokerId,
    schemaVersion = self.schemaVersion,
    timestamp = self.timestamp,
    queueLength = self.queueLength,
    hardwareMatrix = self.hardwareMatrix,
    alerts = self.alerts,
  }
  return serialization.serialize(flat)
end

--- Deserialize a modem message body into a TelemetryPayload
--- @param data string raw serialized data
--- @return TelemetryPayload|nil, string|nil error
function TelemetryPayload.deserialize(data)
  if not data or type(data) ~= "string" or data == "" then
    return nil, "empty or invalid input"
  end

  local ok, result = pcall(serialization.unserialize, data)
  if not ok then
    return nil, "deserialization failed: " .. tostring(result)
  end

  local decoded = result
  if type(decoded) ~= "table" then
    return nil, "deserialized data is not a table"
  end

  -- Validate required fields
  for _, field in ipairs(REQUIRED_FIELDS) do
    if decoded[field] == nil then
      return nil, "missing required field: " .. field
    end
  end

  -- Build and return
  return TelemetryPayload.build(decoded)
end

--- Validate a payload structure (before or after serialization)
--- @param payload table the payload to validate
--- @return boolean, string|nil
function TelemetryPayload.validate(payload)
  if type(payload) ~= "table" then
    return false, "payload must be a table"
  end

  for _, field in ipairs(REQUIRED_FIELDS) do
    if payload[field] == nil then
      return false, "missing required field: " .. field
    end
  end

  -- Type checks
  if type(payload.brokerId) ~= "string" then
    return false, "brokerId must be a string"
  end
  if type(payload.queueLength) ~= "number" then
    return false, "queueLength must be a number"
  end
  if type(payload.hardwareMatrix) ~= "table" then
    return false, "hardwareMatrix must be a table"
  end
  if type(payload.alerts) ~= "table" then
    return false, "alerts must be a table"
  end
  if type(payload.timestamp) ~= "number" then
    return false, "timestamp must be a number"
  end

  return true, nil
end

--- Mock transmit (fire-and-forget modem broadcast)
--- @param modemAddress string target modem address
--- @param port number modem port
--- @return boolean success
function TelemetryPayload:transmit(modemAddress, port)
  if not modemAddress or not port then
    return false
  end
  -- In real OC: component.modem.send(modemAddress, port, self:serialize())
  -- Here we just verify serialization succeeds
  local serialized = self:serialize()
  return serialized ~= nil and #serialized > 0
end

--- Check if an alert is present in this payload
--- @param alertCode string
--- @return boolean
function TelemetryPayload:hasAlert(alertCode)
  for _, alert in ipairs(self.alerts) do
    if alert.code == alertCode then return true end
  end
  return false
end

return TelemetryPayload
