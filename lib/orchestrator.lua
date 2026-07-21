-- Authenticated, opt-in control protocol for AE2-ES modems.
-- This module deliberately has no OpenComputers imports; launchers provide I/O.

local Orchestrator = {}
Orchestrator.__index = Orchestrator

local PROTOCOL = "ae2es-control"
local VERSION = 1
local CONTROL_PORT = 124
local MIN_INTERVAL = 0.1
local MAX_INTERVAL = 60

local COMMAND_FIELDS = {
  PING = { protocol = true, version = true, command = true, senderId = true,
    targetId = true, sentAt = true, nonce = true, auth = true },
  PONG = { protocol = true, version = true, command = true, senderId = true,
    targetId = true, sentAt = true, nonce = true, replyTo = true, auth = true },
  THROTTLE = { protocol = true, version = true, command = true, senderId = true,
    targetId = true, sentAt = true, nonce = true, interval = true, auth = true },
  RESTART = { protocol = true, version = true, command = true, senderId = true,
    targetId = true, sentAt = true, nonce = true, auth = true },
}

local function validString(value, maxLength)
  return type(value) == "string" and #value > 0 and #value <= maxLength
end

local function constantTimeEquals(left, right)
  if type(left) ~= "string" or type(right) ~= "string" or #left ~= #right then
    return false
  end
  local difference = 0
  for index = 1, #left do
    difference = difference + math.abs(left:byte(index) - right:byte(index))
  end
  return difference == 0
end

local function canonical(message)
  local values = {
    message.protocol,
    tostring(message.version),
    message.command,
    message.senderId,
    message.targetId,
    tostring(message.sentAt),
    message.nonce,
    message.replyTo or "",
    message.interval == nil and "" or tostring(message.interval),
  }
  return table.concat(values, "\n")
end

--- Sign an already schema-valid command with a keyed SHA-256-style digest.
--- The digest function is injected from the OC data component at composition time.
function Orchestrator.sign(message, secret, digest)
  if type(secret) ~= "string" or secret == "" or type(digest) ~= "function" then
    return nil
  end
  local ok, signature = pcall(digest, canonical(message) .. "\n" .. secret)
  if ok and type(signature) == "string" then return signature end
  return nil
end

function Orchestrator.verify(message, secret, digest)
  local signature = Orchestrator.sign(message, secret, digest)
  return signature ~= nil and constantTimeEquals(signature, message.auth)
end

function Orchestrator.new(config)
  config = config or {}
  assert(validString(config.id, 64), "Orchestrator requires a local id")

  return setmetatable({
    _id = config.id,
    _enabled = config.enabled == true,
    _port = config.controlPort or CONTROL_PORT,
    _secret = config.secret,
    _digest = config.digest,
    _now = config.now or os.time,
    _modem = config.modem,
    _log = config.log or function() end,
    _onThrottle = config.onThrottle,
    _onRestart = config.onRestart,
    _onPong = config.onPong,
    _allowThrottle = config.allowThrottle == true,
    _allowRestart = config.allowRestart == true,
    _maxClockSkew = config.maxClockSkew or 30,
    _seen = {},
  }, Orchestrator)
end

function Orchestrator:isEnabled()
  return self._enabled
end

function Orchestrator:controlPort()
  return self._port
end

function Orchestrator:setModem(modem)
  self._modem = modem
end

function Orchestrator:_reject(reason)
  self._log("WARN", "Control command ignored: " .. reason)
  return false
end

function Orchestrator:_validateSchema(message)
  if type(message) ~= "table" then return nil, "malformed payload" end
  if message.protocol ~= PROTOCOL or message.version ~= VERSION then
    return nil, "unsupported protocol"
  end
  local fields = COMMAND_FIELDS[message.command]
  if not fields then return nil, "unknown command" end
  for key in pairs(message) do
    if not fields[key] then return nil, "unexpected field " .. tostring(key) end
  end
  if not validString(message.senderId, 64) or not validString(message.targetId, 64)
      or not validString(message.nonce, 80) or not validString(message.auth, 256) then
    return nil, "malformed identity or authentication fields"
  end
  if type(message.sentAt) ~= "number" or message.sentAt % 1 ~= 0 then
    return nil, "malformed timestamp"
  end
  if message.command == "PONG" and not validString(message.replyTo, 80) then
    return nil, "malformed PONG correlation"
  end
  if message.command == "THROTTLE"
      and (type(message.interval) ~= "number"
        or message.interval < MIN_INTERVAL or message.interval > MAX_INTERVAL) then
    return nil, "THROTTLE interval outside safe bounds"
  end
  return true
end

function Orchestrator:_isStale(message, currentTime)
  return math.abs(currentTime - message.sentAt) > self._maxClockSkew
end

function Orchestrator:_isReplay(message, currentTime)
  local key = message.senderId .. "\0" .. message.nonce
  local seenAt = self._seen[key]
  if seenAt then return true end

  -- A nonce remains reserved for at least twice the accepted timestamp window.
  local expiry = currentTime - self._maxClockSkew * 2
  for seenKey, timestamp in pairs(self._seen) do
    if timestamp < expiry then self._seen[seenKey] = nil end
  end
  self._seen[key] = currentTime
  return false
end

function Orchestrator:_send(address, message)
  if not self._modem or type(self._modem.send) ~= "function" then
    return self:_reject("modem unavailable")
  end
  local ok, sent = pcall(self._modem.send, address, self._port, message)
  if not ok or sent == false then return self:_reject("control send failed") end
  return true
end

function Orchestrator:_replyPong(address, request, currentTime)
  local reply = {
    protocol = PROTOCOL,
    version = VERSION,
    command = "PONG",
    senderId = self._id,
    targetId = request.senderId,
    sentAt = currentTime,
    nonce = request.nonce .. ":pong",
    replyTo = request.nonce,
  }
  reply.auth = Orchestrator.sign(reply, self._secret, self._digest)
  if not reply.auth then return self:_reject("PONG authentication unavailable") end
  return self:_send(address, reply)
end

--- Handle one control-port modem message. Never raises on untrusted input.
function Orchestrator:handle(fromAddress, port, message)
  if not self._enabled then return false end
  if port ~= self._port then return false end

  local valid, validationErr = self:_validateSchema(message)
  if not valid then return self:_reject(validationErr) end
  if message.targetId ~= self._id then return false end

  local currentTime = self._now()
  if self:_isStale(message, currentTime) then return self:_reject("stale command") end
  if not Orchestrator.verify(message, self._secret, self._digest) then
    return self:_reject("unauthenticated command")
  end
  if self:_isReplay(message, currentTime) then return self:_reject("replay detected") end

  if message.command == "PING" then
    return self:_replyPong(fromAddress, message, currentTime)
  elseif message.command == "PONG" then
    if type(self._onPong) == "function" then
      local ok, err = pcall(self._onPong, message)
      if not ok then return self:_reject("PONG handler failed: " .. tostring(err)) end
    end
    return true
  elseif message.command == "THROTTLE" then
    if not self._allowThrottle or type(self._onThrottle) ~= "function" then
      return self:_reject("THROTTLE disabled")
    end
    local ok, err = pcall(self._onThrottle, message.interval)
    if not ok then return self:_reject("THROTTLE handler failed: " .. tostring(err)) end
    return true
  elseif message.command == "RESTART" then
    if not self._allowRestart or type(self._onRestart) ~= "function" then
      return self:_reject("RESTART disabled")
    end
    local ok, err = pcall(self._onRestart)
    if not ok then return self:_reject("RESTART handler failed: " .. tostring(err)) end
    return true
  end

  return self:_reject("unhandled command")
end

--- Construct and unicast an authenticated command. Commands are never broadcast.
function Orchestrator:send(address, targetId, command, fields)
  if not self._enabled then return false, "remote control disabled" end
  if type(address) ~= "string" or address == "" or not validString(targetId, 64) then
    return false, "target address and id required"
  end
  local message = {
    protocol = PROTOCOL,
    version = VERSION,
    command = command,
    senderId = self._id,
    targetId = targetId,
    sentAt = self._now(),
    nonce = tostring(self._now()) .. ":" .. tostring(math.random(1, 2147483647)),
  }
  for key, value in pairs(fields or {}) do message[key] = value end
  -- Validate all untrusted/public fields before adding the local signature.
  message.auth = "pending"
  local valid, err = self:_validateSchema(message)
  if not valid then return false, err end
  message.auth = Orchestrator.sign(message, self._secret, self._digest)
  if not message.auth then return false, "control authentication unavailable" end
  return self:_send(address, message)
end

return Orchestrator
