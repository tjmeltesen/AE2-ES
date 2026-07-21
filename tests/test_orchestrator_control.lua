local Assert = require("tests.helpers.assertions")
local Orchestrator = require("supervisor.orchestrator")

local function digest(value)
  return "digest:" .. value
end

local function command(name, now, nonce, extra)
  local message = {
    protocol = "ae2es-control",
    version = 1,
    command = name,
    senderId = "supervisor-a",
    targetId = "broker-a",
    sentAt = now,
    nonce = nonce,
  }
  for key, value in pairs(extra or {}) do message[key] = value end
  message.auth = Orchestrator.sign(message, "shared-secret", digest)
  return message
end

local function newOrchestrator(options)
  options = options or {}
  local sent, logs, throttleCalls, restartCalls = {}, {}, {}, 0
  local orchestrator = Orchestrator.new({
    id = "broker-a",
    enabled = options.enabled ~= false,
    secret = options.secret == false and nil or "shared-secret",
    digest = digest,
    now = function() return options.now or 100 end,
    modem = {
      send = function(address, port, message)
        sent[#sent + 1] = { address = address, port = port, message = message }
        return true
      end,
    },
    log = function(level, message) logs[#logs + 1] = level .. ":" .. message end,
    onThrottle = function(interval) throttleCalls[#throttleCalls + 1] = interval end,
    onRestart = function() restartCalls = restartCalls + 1 end,
    allowThrottle = options.allowThrottle == true,
    allowRestart = options.allowRestart == true,
  })
  return orchestrator, sent, logs, throttleCalls, function() return restartCalls end
end

Assert.startTest("control PING accepts authenticated command and responds PONG")
do
  local orchestrator, sent = newOrchestrator()
  local handled = orchestrator:handle("modem-supervisor", 124, command("PING", 100, "ping-1"))
  Assert.isTrue(handled)
  Assert.equal(1, #sent)
  Assert.equal("modem-supervisor", sent[1].address, "PONG must unicast to the sender")
  Assert.equal(124, sent[1].port)
  Assert.equal("PONG", sent[1].message.command)
  Assert.equal("broker-a", sent[1].message.senderId)
  Assert.equal("supervisor-a", sent[1].message.targetId)
  Assert.isTrue(Orchestrator.verify(sent[1].message, "shared-secret", digest))
end
Assert.endTest()

Assert.startTest("control sends authenticated PING only as a unicast")
do
  local sent = {}
  local orchestrator = Orchestrator.new({
    id = "supervisor-a",
    enabled = true,
    secret = "shared-secret",
    digest = digest,
    now = function() return 100 end,
    modem = {
      send = function(address, port, message)
        sent[#sent + 1] = { address = address, port = port, message = message }
        return true
      end,
    },
  })
  Assert.isTrue(orchestrator:send("modem-broker", "broker-a", "PING"))
  Assert.equal(1, #sent)
  Assert.equal("modem-broker", sent[1].address)
  Assert.equal(124, sent[1].port)
  Assert.equal("PING", sent[1].message.command)
  Assert.isTrue(Orchestrator.verify(sent[1].message, "shared-secret", digest))
end
Assert.endTest()

Assert.startTest("disabled remote control preserves passive modem behavior")
do
  local orchestrator, sent, logs = newOrchestrator({ enabled = false })
  Assert.isFalse(orchestrator:handle("modem", 124, command("PING", 100, "disabled")))
  Assert.equal(0, #sent)
  Assert.equal(0, #logs)
end
Assert.endTest()

Assert.startTest("control rejects malformed unknown stale and unauthenticated commands")
do
  local orchestrator, sent, logs = newOrchestrator()
  Assert.isFalse(orchestrator:handle("modem", 124, "not a table"))
  Assert.isFalse(orchestrator:handle("modem", 124, command("ERASE_ALL", 100, "unknown")))
  Assert.isFalse(orchestrator:handle("modem", 124, command("PING", 1, "stale")))
  local unauthenticated = command("PING", 100, "bad-auth")
  unauthenticated.auth = "wrong"
  Assert.isFalse(orchestrator:handle("modem", 124, unauthenticated))
  Assert.equal(0, #sent)
  Assert.equal(4, #logs, "every rejected control message must be logged")
end
Assert.endTest()

Assert.startTest("control rejects replayed authenticated commands")
do
  local orchestrator, sent, logs = newOrchestrator()
  local ping = command("PING", 100, "repeat-me")
  Assert.isTrue(orchestrator:handle("modem", 124, ping))
  Assert.isFalse(orchestrator:handle("modem", 124, ping))
  Assert.equal(1, #sent, "replayed PING must not receive another PONG")
  Assert.match("replay", logs[#logs])
end
Assert.endTest()

Assert.startTest("THROTTLE and RESTART require their individual rollout flags")
do
  -- enabled=true represents enableRemoteControl alone. Neither mutating
  -- command may activate until its separate allow flag is set.
  local controlOnly, _, _, controlOnlyThrottle, controlOnlyRestarts = newOrchestrator()
  Assert.isFalse(controlOnly:handle(
    "modem", 124, command("THROTTLE", 100, "control-only-throttle", { interval = 2.5 })
  ))
  Assert.isFalse(controlOnly:handle("modem", 124, command("RESTART", 100, "control-only-restart")))
  Assert.equal(0, #controlOnlyThrottle)
  Assert.equal(0, controlOnlyRestarts())

  local throttleOnly, _, _, throttleCalls, throttleOnlyRestarts =
    newOrchestrator({ allowThrottle = true })
  Assert.isTrue(throttleOnly:handle(
    "modem", 124, command("THROTTLE", 100, "throttle-enabled", { interval = 2.5 })
  ))
  Assert.isFalse(throttleOnly:handle("modem", 124, command("RESTART", 100, "restart-still-disabled")))
  Assert.equal(1, #throttleCalls)
  Assert.equal(0, throttleOnlyRestarts())

  local restartOnly, _, _, restartOnlyThrottle, restartCalls =
    newOrchestrator({ allowRestart = true })
  Assert.isFalse(restartOnly:handle(
    "modem", 124, command("THROTTLE", 100, "throttle-still-disabled", { interval = 2.5 })
  ))
  Assert.isTrue(restartOnly:handle("modem", 124, command("RESTART", 100, "restart-enabled")))
  Assert.equal(0, #restartOnlyThrottle)
  Assert.equal(1, restartCalls())
end
Assert.endTest()

Assert.startTest("THROTTLE validates bounded intervals before invoking broker")
do
  local orchestrator, sent, logs, throttleCalls = newOrchestrator({ allowThrottle = true })
  Assert.isFalse(orchestrator:handle("modem", 124, command("THROTTLE", 100, "short", { interval = 0.01 })))
  Assert.isFalse(orchestrator:handle("modem", 124, command("THROTTLE", 100, "long", { interval = 61 })))
  Assert.isTrue(orchestrator:handle("modem", 124, command("THROTTLE", 100, "valid", { interval = 2.5 })))
  Assert.equal(1, #throttleCalls)
  Assert.equal(2.5, throttleCalls[1])
  Assert.equal(0, #sent, "THROTTLE has no response until a separate acknowledgement protocol exists")
  Assert.greaterThan(1, #logs)
end
Assert.endTest()

Assert.startTest("RESTART requires opt-in authentication and replay protection")
do
  local orchestrator, _, _, _, restartCalls = newOrchestrator()
  Assert.isFalse(orchestrator:handle("modem", 124, command("RESTART", 100, "restart-disabled")))
  Assert.equal(0, restartCalls())

  local enabled, _, _, _, enabledRestartCalls = newOrchestrator({ allowRestart = true })
  local restart = command("RESTART", 100, "restart-once")
  Assert.isTrue(enabled:handle("modem", 124, restart))
  Assert.isFalse(enabled:handle("modem", 124, restart))
  Assert.equal(1, enabledRestartCalls())
end
Assert.endTest()
