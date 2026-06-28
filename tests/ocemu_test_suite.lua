--[[
ocemu_test_suite.lua — Real OC API test suite for AE2-ES
Runs inside OCEmu with actual OpenComputers component mocks.
Tests module loading, config save/load, broker execution, and I/O.
]]--

local results = { passed = 0, failed = 0, errors = {} }

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    results.passed = results.passed + 1
    io.write(string.format("  [PASS] %s\n", name))
  else
    results.failed = results.failed + 1
    table.insert(results.errors, { name = name, error = tostring(err) })
    io.write(string.format("  [FAIL] %s: %s\n", name, tostring(err)))
  end
end

-- Override io.read for headless CI (returns empty string by default)
local _orig_read = io.read
local _input_queue = {}
io.read = function(...)
  if #_input_queue > 0 then
    return table.remove(_input_queue, 1)
  end
  return ""
end

io.write("=== AE2-ES OCEmu Real API Test Suite ===\n\n")

-- ===========================================================================
-- Test Group 1: Module Loading (real OC API)
-- ===========================================================================
io.write("--- Group 1: Module Loading ---\n")

test("config_ui loads (real OC API)", function()
  -- Suppress entry point so wizard doesn't block on io.read
  package.loaded["src.config_ui"] = true
  local mod = require("home.src.config_ui")
  assert(type(mod) == "table", "config_ui not a table")
  assert(type(mod.CONFIG_PATH) == "string", "missing CONFIG_PATH")
  assert(mod.PHASES ~= nil or mod.ConfigUI ~= nil, "no ConfigUI or PHASES")
end)

test("exec_broker loads (real OC API)", function()
  package.loaded["src.exec_broker"] = true
  local mod = require("home.src.exec_broker")
  assert(type(mod) == "table", "exec_broker not a table")
  assert(type(mod.PHASES) == "table", "missing PHASES")
  assert(mod.PHASES.BUFFERING ~= nil, "missing BUFFERING phase")
end)

test("hal loads (real OC API)", function()
  local mod = require("home.src.hal")
  assert(type(mod) == "table", "hal not a table")
  assert(type(mod.new) == "function", "hal.new not a function")
  local instance = mod:new()
  assert(type(instance) == "table", "HAL instance not a table")
end)

test("supervisor loads (real OC API)", function()
  package.loaded["src.supervisor"] = true
  local mod = require("home.src.supervisor")
  assert(type(mod) == "table", "supervisor not a table")
end)

test("log modules load", function()
  local entry = require("home.src.log_entry")
  local buf = require("home.src.log_ring_buffer")
  assert(type(entry.new) == "function", "log_entry.new missing")
  assert(type(buf.new) == "function", "log_ring_buffer.new missing")
end)

-- ===========================================================================
-- Test Group 2: Real OC Component API Interaction
-- ===========================================================================
io.write("\n--- Group 2: OC Component API ---\n")

test("component.list() returns iterator", function()
  local c = require("component")
  local iter = c.list()
  assert(type(iter) == "function", "component.list not a function")
end)

test("component.proxy() returns table", function()
  local c = require("component")
  -- Create a temporary component in the OCEmu registry
  local addr = "aaaa0000-0000-0000-0000-000000000000"
  local proxy = c.proxy(addr)
  assert(type(proxy) == "table", "component.proxy didn't return table")
end)

test("component.isAvailable() works", function()
  local c = require("component")
  -- GPU should be available in OCEmu
  local result = c.isAvailable("gpu")
  -- Returns boolean
  assert(type(result) == "boolean" or result == nil, "isAvailable wrong type")
end)

test("computer API works", function()
  local computer = require("computer")
  assert(type(computer.uptime) == "function", "computer.uptime missing")
  local t = computer.uptime()
  assert(type(t) == "number", "uptime not a number")
end)

test("filesystem API works", function()
  local fs = require("filesystem")
  assert(type(fs.exists) == "function" or type(fs.isDirectory) == "function",
    "filesystem API missing")
end)

-- ===========================================================================
-- Test Group 3: Config UI Save/Load (real filesystem)
-- ===========================================================================
io.write("\n--- Group 3: Config Save/Load ---\n")

test("config_ui saveConfig creates file", function()
  package.loaded["src.config_ui"] = nil  -- allow fresh load
  local ConfigUI = require("home.src.config_ui")
  -- Override io.read to automate the wizard
  -- Just test the save infrastructure directly
  local ui = ConfigUI.new({})
  -- Manually set config for testing
  ui._config = {
    brokerId = "test-broker",
    itemBufferAddr = "test-addr-001",
    fluidBufferAddr = "test-addr-002",
    databaseAddr = "test-db-001",
    machines = {
      { laneId = "Lane 1", machineAddr = "test-machine-001" },
    },
    machineTransposers = {
      ["Lane 1"] = { dualInterface = "di-001", transposerAddr = "tr-001", machineAddr = "test-machine-001", pull = 2, push = 3, ["return"] = 5 },
    },
  }
  local ok, err = ui:saveConfig()
  assert(ok, "saveConfig failed: " .. (err or "unknown"))
  -- Verify file exists
  local fs = require("filesystem")
  if fs and fs.exists then
    assert(fs.exists(ConfigUI.CONFIG_PATH), "config file not created at " .. ConfigUI.CONFIG_PATH)
  end
end)

test("config_ui loadConfig reads file", function()
  local ConfigUI = require("home.src.config_ui")
  local ui = ConfigUI.new({})
  local ok, cfg = ui:loadConfig()
  assert(ok, "loadConfig failed")
  assert(type(cfg) == "table", "config not a table")
  assert(cfg.brokerId == "test-broker", "brokerId mismatch: " .. tostring(cfg.brokerId))
  assert(#cfg.machines == 1, "wrong machine count")
end)

-- ===========================================================================
-- Test Group 4: Exec Broker Execution
-- ===========================================================================
io.write("\n--- Group 4: Exec Broker Execution ---\n")

test("exec_broker constructs with lane config", function()
  package.loaded["src.exec_broker"] = nil
  local ExecBroker = require("home.src.exec_broker")
  -- Suppress entry point
  local broker = ExecBroker.new({
    brokerId = "test-ocemu-broker",
    machines = {
      { laneId = "Lane 1", machineAddr = "mach-01" },
    },
    machineTransposers = {
      ["Lane 1"] = { dualInterface = "di-01", transposerAddr = "tr-01", machineAddr = "mach-01", pull = 2, push = 3, ["return"] = 5 },
    },
    itemBufferAddr = "buf-01",
    fluidBufferAddr = "buf-02",
    databaseAddr = "db-01",
    pollInterval = 0.5,
    heartbeatInterval = 2.0,
    queueSize = 64,
  })
  assert(type(broker) == "table", "broker not created")
  assert(type(broker.getPhase) == "function", "getPhase missing")
  local phase = broker:getPhase()
  assert(phase == ExecBroker.PHASES.BUFFERING, "wrong initial phase: " .. tostring(phase))
end)

test("exec_broker tick runs without error", function()
  local ExecBroker = require("home.src.exec_broker")
  local broker = ExecBroker.new({
    brokerId = "test-tick-broker",
    machines = {
      { laneId = "Lane 1", machineAddr = "mach-01" },
    },
    machineTransposers = {},
    pollInterval = 0.5,
    heartbeatInterval = 999, -- don't send telemetry
    queueSize = 64,
  })
  -- Override clock for deterministic testing
  local tickCount = 0
  ExecBroker._clockOverride = function()
    tickCount = tickCount + 1
    return tickCount * 10  -- advance time
  end
  -- Run 3 ticks
  for _ = 1, 3 do
    local ok = broker:tick()
    assert(ok, "tick returned false")
  end
  assert(broker:getTickCount() == 3, "wrong tick count")
  ExecBroker._clockOverride = nil
end)

test("exec_broker phase cycle (no buffer)", function()
  local ExecBroker = require("home.src.exec_broker")
  local broker = ExecBroker.new({
    brokerId = "test-phase-broker",
    machines = {
      { laneId = "Lane 1", machineAddr = "mach-01" },
    },
    machineTransposers = {},
    pollInterval = 0.01,
    heartbeatInterval = 999,
    queueSize = 64,
    bufferFeeder = function() return nil end, -- no data
  })
  ExecBroker._clockOverride = function() return 100 end
  -- Run 10 ticks — should stay in BUFFERING (no data)
  for _ = 1, 10 do
    broker:tick()
  end
  local phase = broker:getPhase()
  assert(phase == ExecBroker.PHASES.BUFFERING, "should stay in BUFFERING: " .. tostring(phase))
  ExecBroker._clockOverride = nil
end)

-- ===========================================================================
-- Test Group 5: Logger/Diagnostics
-- ===========================================================================
io.write("\n--- Group 5: Logger & Diagnostics ---\n")

test("broker_logger creates instance", function()
  local BrokerLogger = require("home.src.broker_logger")
  local logger = BrokerLogger.new("test-ocemu")
  assert(type(logger) == "table", "logger not created")
  assert(type(logger.info) == "function", "info missing")
  assert(type(logger.error) == "function", "error missing")
end)

test("broker_logger logs without error", function()
  local BrokerLogger = require("home.src.broker_logger")
  local logger = BrokerLogger.new("test-ocemu")
  logger:info("test info message")
  logger:warn("test warning")
  logger:error("test error")
  local recent = logger:getRecent(3)
  assert(type(recent) == "table", "getRecent not returning table")
end)

test("log_entry creates valid entry", function()
  local LogEntry = require("home.src.log_entry")
  local entry = LogEntry.new("test-broker", "INFO", "test message")
  assert(type(entry) == "table", "entry not created")
  assert(entry.originId == "test-broker", "originId wrong")
  assert(entry.severity == "INFO", "severity wrong")
end)

test("log_ring_buffer appends and retrieves", function()
  local LogRingBuffer = require("home.src.log_ring_buffer")
  local LogEntry = require("home.src.log_entry")
  local buf = LogRingBuffer.new(10)
  for i = 1, 5 do
    buf:append(LogEntry.new("test", "INFO", "msg " .. i))
  end
  local recent = buf:getLatest(3)
  assert(type(recent) == "table", "getLatest not table")
end)

-- ===========================================================================
-- Results
-- ===========================================================================
io.write(string.format("\n=== Results: %d passed, %d failed ===\n",
  results.passed, results.failed))

if results.failed > 0 then
  io.write("Failures:\n")
  for _, e in ipairs(results.errors) do
    io.write(string.format("  %s: %s\n", e.name, e.error))
  end
  os.exit(1)
end

os.exit(0)
