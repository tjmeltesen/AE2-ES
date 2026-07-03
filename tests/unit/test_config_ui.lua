--===========================================================================
-- test_config_ui.lua — Unit tests for src/config_ui.lua (A13)
-- Tier 1: Vanilla Lua 5.3, no OC runtime. Mocks GPU, component, filesystem.
-- Tests: construction, config persistence, component detection, connectivity,
--   config building, menu navigation, reset, HAL side management, wizard
--===========================================================================

--===========================================================================
-- Minimal test framework (self-contained, matches project style)
--===========================================================================

local test_results = {
    passed = 0,
    failed = 0,
    errors = {},
}

local function assert_equal(actual, expected, msg)
    msg = msg or ""
    if actual == expected then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: expected %s, got %s",
        msg, tostring(expected), tostring(actual))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

local function assert_not_nil(val, msg)
    msg = msg or ""
    if val ~= nil then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: expected non-nil, got nil", msg)
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

local function assert_nil(val, msg)
    msg = msg or ""
    if val == nil then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: expected nil, got %s", msg, tostring(val))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

local function assert_true(val, msg)
    msg = msg or ""
    if val then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: expected true, got %s", msg, tostring(val))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

local function assert_false(val, msg)
    msg = msg or ""
    if not val then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: expected false, got %s", msg, tostring(val))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

local function assert_table_contains(t, key, msg)
    msg = msg or ""
    if t[key] ~= nil then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: table missing key '%s'", msg, tostring(key))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

--===========================================================================
-- Mock OC components
--===========================================================================

local MockGPU = {}
MockGPU.__index = MockGPU
function MockGPU.new()
    return setmetatable({
        _fg = 0xFFFFFF,
        _bg = 0x000000,
        _buffer = {},
        _resolution = { 80, 25 },
    }, MockGPU)
end
function MockGPU:setForeground(color) self._fg = color end
function MockGPU:setBackground(color) self._bg = color end
function MockGPU:getResolution() return self._resolution[1], self._resolution[2] end
function MockGPU:set(x, y, text) self._buffer[#self._buffer + 1] = { x, y, text } end

local MockScreen = {}
MockScreen.__index = MockScreen
function MockScreen.new() return setmetatable({}, MockScreen) end

local MockTerm = {}
MockTerm.__index = MockTerm
function MockTerm.new()
    return setmetatable({
        _inputQueue = {},
        _output = {},
    }, MockTerm)
end
function MockTerm:clear() table.insert(self._output, "clear") end
function MockTerm:setCursor(x, y) table.insert(self._output, "cursor:" .. x .. "," .. y) end
function MockTerm:write(text) table.insert(self._output, "write:" .. text) end
function MockTerm:read()
    if #self._inputQueue > 0 then
        return table.remove(self._inputQueue, 1)
    end
    return ""
end

-- Mock component library
local MockComponent = {}
MockComponent.__index = MockComponent
function MockComponent.new(components)
    local self = setmetatable({
        _components = components or {},
        _proxies = {},
    }, MockComponent)
    -- Public API: regular functions, not methods (OC component lib style)
    self.list = function(filter)
        local keys = {}
        for addr, _ in pairs(self._components) do
            table.insert(keys, addr)
        end
        table.sort(keys)
        local i = 0
        return function()
            i = i + 1
            if i > #keys then return nil end
            return keys[i], self._components[keys[i]]
        end
    end
    self.isAvailable = function(name)
        for _, typeName in pairs(self._components) do
            if typeName == name then return true end
        end
        return false
    end
    self.proxy = function(address)
        if not address or address == "" then return nil end
        -- Only create proxy for known addresses (matches real OC behavior
        -- where unknown addresses return nil from component.proxy)
        if not self._components[address] then return nil end
        if not self._proxies[address] then
            local compType = self._components[address] or "unknown"
            local proxy = {
                address = address,
                type = compType,
                open = function(_, port) return true end,
                close = function(_, port) return true end,
            }
            self._proxies[address] = proxy
        end
        return self._proxies[address]
    end
    return self
end

-- Mock filesystem
local MockFilesystem = {}
MockFilesystem.__index = MockFilesystem
function MockFilesystem.new()
    local self = setmetatable({
        _files = {},
    }, MockFilesystem)
    -- OC library functions style (no implicit self)
    self.exists = function(path) return self._files[path] ~= nil end
    return self
end

--===========================================================================
-- Helper: Create mock components for a test scenario
--===========================================================================

local function makeComponents()
    return MockComponent.new({
        ["abcd-1234-modem"] = "modem",
        ["abcd-1234-transposer"] = "transposer",
        ["abcd-1234-redstone"] = "redstone",
        ["abcd-5678-ctrl"] = "me_controller",
        ["abcd-9012-iface"] = "me_interface",
        ["abcd-3456-iface"] = "me_interface",
        ["abcd-7890-gtmach"] = "gt_machine",
        ["abcd-1111-gtmach"] = "gt_machine",
    })
end

--===========================================================================
-- Test runner helper
--===========================================================================

local function reportGroup(name)
    print("")
    print("--- " .. name .. " ---")
end

--===========================================================================
-- Group 1: Construction and I/O detection
--===========================================================================
do
    reportGroup("Group 1: Construction and I/O detection")

    -- Test 1.1: Constructor with mock GPU
    local gpu = MockGPU.new()
    local screen = MockScreen.new()
    local term = MockTerm.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()

    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        screen = screen,
        termLib = term,
        filesystem = fs,
        component = comp,
    })

    assert_not_nil(ui, "1.1: ConfigUI instance created")
    assert_true(ui:hasGPU(), "1.1: GPU mode detected")

    -- Test 1.2: Terminal fallback mode
    local uiTerm = ConfigUI.new("/tmp/test2.cfg", {
        filesystem = fs,
        component = comp,
    })
    assert_not_nil(uiTerm, "1.2: Terminal fallback instance")
    assert_false(uiTerm:hasGPU(), "1.2: Terminal mode (no GPU injected)")

    -- Test 1.3: Default config path
    assert_equal(ui._configPath, "/tmp/test.cfg", "1.3: Custom config path")
end

--===========================================================================
-- Group 2: Default config & reset
--===========================================================================
do
    reportGroup("Group 2: Default config & reset")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })

    -- Test 2.1: Reset yields default config structure
    local config = ui:resetConfig()
    assert_not_nil(config, "2.1: Reset produced config")
    assert_equal(config.brokerId, "", "2.1: brokerId defaults to empty")
    assert_equal(config.telemetryPort, 123, "2.1: telemetryPort defaults to 123")
    assert_equal(config.pollInterval, 0.5, "2.1: pollInterval defaults to 0.5")
    assert_equal(config.heartbeatInterval, 2.0, "2.1: heartbeatInterval defaults to 2.0")
    assert_equal(config.debounceWindow, 1.5, "2.1: debounceWindow defaults to 1.5")
    assert_equal(config.queueSize, 64, "2.1: queueSize defaults to 64")
    assert_equal(#(config.machines), 0, "2.1: machines empty by default")
    assert_equal(config.modemAddress, "", "2.1: modemAddress empty by default")
    assert_equal(config.redstoneAddress, "", "2.1: redstoneAddress empty")
    assert_equal(config.meControllerAddr, "", "2.1: meControllerAddr empty")

    -- Test 2.2: HAL side map is populated with defaults
    assert_not_nil(config.halSideMap, "2.2: halSideMap exists")
    assert_equal(config.halSideMap.inputBus, 3, "2.2: inputBus -> front")
    assert_equal(config.halSideMap.outputBus, 2, "2.2: outputBus -> back")
    assert_equal(config.halSideMap.interface, 1, "2.2: interface -> top")

    -- Test 2.3: getConfig returns stored config
    assert_equal(ui:getConfig(), config, "2.3: getConfig same as reset config")
end

--===========================================================================
-- Group 3: Config serialization
--===========================================================================
do
    reportGroup("Group 3: Config serialization")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })
    ui:resetConfig()

    -- Populate config
    ui._config.brokerId = "test-broker"
    ui._config.modemAddress = "abcd-1234-modem"
    ui._config.telemetryPort = 456
    ui._config.machines = { "abcd-7890-gtmach" }
    ui._config.machineTypes = { ["abcd-7890-gtmach"] = 1 }
    ui._config.pollInterval = 1.0

    -- Test 3.1: Serialize produces loadable Lua
    local serialized = ui:_serializeTable(ui._config, "", true)
    assert_not_nil(serialized, "3.1: Serialized output exists")
    assert_true(#serialized > 10, "3.1: Serialized output has content")

    -- Test 3.2: Serialized output round-trips via load
    local loadOk, chunk = pcall(load, "return " .. serialized)
    assert_true(loadOk, "3.2: Serialized Lua is loadable")
    if loadOk then
      local execOk, loaded = pcall(chunk)
      assert_true(execOk, "3.2: Chunk executes")
      assert_equal(type(loaded), "table", "3.2: Loaded result is table")
      assert_equal(loaded.brokerId, "test-broker", "3.2: brokerId round-trips")
      assert_equal(loaded.telemetryPort, 456, "3.2: telemetryPort round-trips")
      assert_equal(loaded.machines[1], "abcd-7890-gtmach", "3.2: machines round-trips")
    end

    -- Test 3.3: Array serialization
    local arrStr = ui:_serializeTable({ "a", "b", "c" }, "", true)
    assert_true(#arrStr > 0, "3.3: Array serialized")
    local loadOk2, chunk2 = pcall(load, "return " .. arrStr)
    assert_true(loadOk2, "3.3: Array round-trips")
    if loadOk2 then
      local execOk2, arrLoaded = pcall(chunk2)
      assert_true(execOk2, "3.3: Array executes")
      assert_equal(arrLoaded[1], "a", "3.3: arr[1] = a")
      assert_equal(arrLoaded[3], "c", "3.3: arr[3] = c")
    end

    -- Test 3.4: Empty table serialization
    local emptyStr = ui:_serializeTable({}, "", true)
    assert_equal(emptyStr, "{}", "3.4: Empty table -> {}")

    -- Test 3.5: Nested table serialization
    local nested = { outer = { inner = "value" } }
    local nestedStr = ui:_serializeTable(nested, "", true)
    local loadOk3, chunk3 = pcall(load, "return " .. nestedStr)
    assert_true(loadOk3, "3.5: Nested round-trips")
    if loadOk3 then
      local execOk3, nestedLoaded = pcall(chunk3)
      assert_true(execOk3, "3.5: Nested executes")
      assert_equal(nestedLoaded.outer.inner, "value", "3.5: Nested value preserved")
    end

    -- Test 3.6: Value serialization (primitive types)
    assert_equal(ui:_serializeValue("hello"), "\"hello\"", "3.6: String")
    assert_equal(ui:_serializeValue(42), "42", "3.6: Integer")
    assert_equal(ui:_serializeValue(1.5), "1.5", "3.6: Float")
    assert_equal(ui:_serializeValue(true), "true", "3.6: true")
    assert_equal(ui:_serializeValue(false), "false", "3.6: false")
    assert_equal(ui:_serializeValue(nil), "nil", "3.6: nil")
end

--===========================================================================
-- Group 4: Config persistence (save/load)
--===========================================================================
do
    reportGroup("Group 4: Config persistence")

    local gpu = MockGPU.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")

    -- Use a real-filesystem-backed mock for the exists() check.
    -- config_ui requires fs.exists() from the OC filesystem lib,
    -- but actual I/O uses io.open (real filesystem).
    local realFs = { exists = function(path)
      local f = io.open(path, "r")
      if f then f:close(); return true end
      return false
    end }

    -- Test 4.1: Save config to filesystem (uses real io.open)
    local ui = ConfigUI.new("/tmp/ae2es_test.cfg", {
        gpu = gpu,
        filesystem = realFs,
        component = comp,
    })
    ui:resetConfig()
    ui._config.brokerId = "persist-broker"
    ui._config.modemAddress = "abcd-1234-modem"
    ui._config.telemetryPort = 789
    ui._config.machines = { "abcd-7890-gtmach", "abcd-1111-gtmach" }

    local ok, err = ui:saveConfig()
    assert_true(ok, "4.1: Save succeeded")
    assert_nil(err, "4.1: No error on save")

    -- Test 4.2: Load config from filesystem
    local ui2 = ConfigUI.new("/tmp/ae2es_test.cfg", {
        gpu = gpu,
        filesystem = realFs,
        component = comp,
    })
    local loaded, loadErr = ui2:loadConfig()
    assert_not_nil(loaded, "4.2: Load succeeded")
    assert_nil(loadErr, "4.2: No load error")
    if loaded then
      assert_equal(loaded.brokerId, "persist-broker", "4.2: brokerId persisted")
      assert_equal(loaded.telemetryPort, 789, "4.2: telemetryPort persisted")
      assert_equal(#loaded.machines, 2, "4.2: machine count persisted")
      assert_equal(loaded.machines[1], "abcd-7890-gtmach", "4.2: machine[1] persisted")
      assert_equal(loaded.version, ConfigUI.VERSION, "4.2: version marker saved")
    end

    -- Test 4.3: Load from non-existent file returns nil
    local ui3 = ConfigUI.new("/tmp/nonexistent_ae2es_test.cfg", {
        gpu = gpu,
        filesystem = realFs,
        component = comp,
    })
    local missing, missingErr = ui3:loadConfig()
    assert_nil(missing, "4.3: Missing file returns nil")
    assert_not_nil(missingErr, "4.3: Missing file returns error string")

    -- Test 4.4: Save with nil config
    local ui4 = ConfigUI.new("/tmp/noconfig_ae2es_test.cfg", {
        gpu = gpu,
        filesystem = realFs,
        component = comp,
    })
    local ok4, err4 = ui4:saveConfig()
    assert_false(ok4, "4.4: Save without config fails")
    assert_not_nil(err4, "4.4: Error on save without config")

    -- Test 4.5: version marker and _savedAt on saved config
    local ui5 = ConfigUI.new("/tmp/meta_ae2es_test.cfg", {
        gpu = gpu,
        filesystem = realFs,
        component = comp,
    })
    ui5:resetConfig()
    ui5._config.brokerId = "meta-broker"
    ui5:saveConfig()
    local reloaded, _ = ui5:loadConfig()
    assert_not_nil(reloaded, "4.5: Reloaded meta config")
    assert_equal(reloaded.version, ConfigUI.VERSION, "4.5: version marker present")
    assert_not_nil(reloaded._savedAt, "4.5: _savedAt timestamp present")

    -- Cleanup temp files
    os.remove("/tmp/ae2es_test.cfg")
    os.remove("/tmp/meta_ae2es_test.cfg")
end

--===========================================================================
-- Group 5: Component detection
--===========================================================================
do
    reportGroup("Group 5: Component detection")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })

    -- Test 5.1: detectComponents finds all mocked types
    local detected = ui:detectComponents()
    assert_not_nil(detected, "5.1: Detection ran")
    assert_not_nil(detected.modem, "5.1: Modem found")
    assert_not_nil(detected.transposer, "5.1: Transposer found")
    assert_not_nil(detected.redstone, "5.1: Redstone found")
    assert_not_nil(detected.meController, "5.1: ME Controller found")
    assert_equal(#detected.meInterfaces, 2, "5.1: Two ME Interfaces found")
    assert_equal(#detected.gtMachines, 2, "5.1: Two GT machines found")

    -- Test 5.2: Detected component addresses
    assert_equal(detected.modem.address, "abcd-1234-modem", "5.2: Modem address")
    assert_equal(detected.transposer.address, "abcd-1234-transposer", "5.2: Transposer address")
    assert_equal(detected.redstone.address, "abcd-1234-redstone", "5.2: Redstone address")

    -- Test 5.3: GT machines sorted by address
    local expectedMachines = { "abcd-1111-gtmach", "abcd-7890-gtmach" }
    for i, entry in ipairs(detected.gtMachines) do
        assert_equal(entry.address, expectedMachines[i],
            "5.3: Machine " .. i .. " address sorted")
    end

    -- Test 5.4: findComponent by type
    local found = ui:findComponent("modem")
    assert_not_nil(found, "5.4: findComponent finds modem")
    assert_equal(found.address, "abcd-1234-modem", "5.4: Modem via findComponent")

    local notFound = ui:findComponent("nonexistent")
    assert_nil(notFound, "5.4: findComponent returns nil for missing type")

    -- Test 5.5: Cached detection
    local cached = ui:detectComponents()
    assert_equal(cached, detected, "5.5: Detection result is cached")

    -- Test 5.6: Empty component list
    local emptyComp = MockComponent.new({})
    local uiEmpty = ConfigUI.new("/tmp/empty.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = emptyComp,
    })
    local emptyDetected = uiEmpty:detectComponents()
    assert_not_nil(emptyDetected, "5.6: Detection on empty list")
    assert_equal(#emptyDetected.components, 0, "5.6: Zero components found")
end

--===========================================================================
-- Group 6: Connectivity testing
--===========================================================================
do
    reportGroup("Group 6: Connectivity testing")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })

    -- Test 6.1: Test valid modem address
    local ok, msg = ui:testComponent("abcd-1234-modem", "modem")
    assert_true(ok, "6.1: Modem test passes")
    assert_true(#msg > 0, "6.1: Modem test returns message")

    -- Test 6.2: Test valid redstone address
    local ok2, msg2 = ui:testComponent("abcd-1234-redstone")
    assert_true(ok2, "6.2: Redstone test passes")

    -- Test 6.3: Test with empty address
    local ok3, msg3 = ui:testComponent("", "modem")
    assert_false(ok3, "6.3: Empty address returns false")
    assert_true(#msg3 > 0, "6.3: Empty address returns error message")

    -- Test 6.4: Test with nonexistent address
    local ok4, msg4 = ui:testComponent("nonexistent-address")
    assert_false(ok4, "6.4: Nonexistent address returns false")

    -- Test 6.5: Test with nil address
    local ok5, msg5 = ui:testComponent(nil, "modem")
    assert_false(ok5, "6.5: Nil address returns false")
end

--===========================================================================
-- Group 7: Building exec_broker config
--===========================================================================
do
    reportGroup("Group 7: Building exec_broker config")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })

    -- Setup config
    ui:resetConfig()
    ui._config.brokerId = "exec-target-broker"
    ui._config.modemAddress = "abcd-1234-modem"
    ui._config.telemetryPort = 999
    ui._config.machines = { "abcd-7890-gtmach" }
    ui._config.machineTypes = { ["abcd-7890-gtmach"] = 128 }
    ui._config.pollInterval = 0.25
    ui._config.heartbeatInterval = 5.0
    ui._config.debounceWindow = 2.0
    ui._config.queueSize = 32
    ui._config.halSideMap.inputBus = 0

    -- Test 7.1: buildExecConfig returns valid config table
    local execCfg = ui:buildExecConfig()
    assert_not_nil(execCfg, "7.1: Exec config built")
    assert_equal(execCfg.brokerId, "exec-target-broker", "7.1: brokerId passed through")
    assert_equal(execCfg.telemetryPort, 999, "7.1: telemetryPort passed through")
    assert_equal(execCfg.pollInterval, 0.25, "7.1: pollInterval passed through")
    assert_equal(execCfg.heartbeatInterval, 5.0, "7.1: heartbeatInterval passed through")
    assert_equal(execCfg.debounceWindow, 2.0, "7.1: debounceWindow passed through")
    assert_equal(execCfg.queueSize, 32, "7.1: queueSize passed through")

    -- Test 7.2: HAL config is passed through
    assert_not_nil(execCfg.halConfig, "7.2: halConfig exists")
    assert_equal(execCfg.halConfig.sideMap.inputBus, 0, "7.2: HAL side overrides applied")

    -- Test 7.3: Modem is resolved to proxy
    assert_not_nil(execCfg.modem, "7.3: Modem resolved to proxy")
    if execCfg.modem then
        assert_equal(execCfg.modem.address, "abcd-1234-modem", "7.3: Modem proxy address")
    end

    -- Test 7.4: buildExecConfig with nil config
    local uiNoConfig = ConfigUI.new("/tmp/none.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })
    local nilCfg = uiNoConfig:buildExecConfig()
    assert_nil(nilCfg, "7.4: No config returns nil")

    -- Test 7.5: Machines are included
    assert_not_nil(execCfg.machines, "7.5: Machines table present")
    assert_not_nil(execCfg.machines["abcd-7890-gtmach"], "7.5: Machine entry exists")
end

--===========================================================================
-- Group 8: Side display labels
--===========================================================================
do
    reportGroup("Group 8: Side management")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })
    ui:resetConfig()

    -- Test 8.1: All HAL roles have defaults
    for _, role in ipairs({ "inputBus", "outputBus", "inputHatch", "outputHatch", "interface" }) do
        local side = ui._config.halSideMap[role]
        assert_not_nil(side, "8.1: HAL role " .. role .. " has a default side")
        assert_true(side >= 0 and side <= 5, "8.1: Side " .. side .. " is valid (0-5)")
    end

    -- Test 8.2: Can update HAL side mapping
    ui._config.halSideMap.inputBus = 4
    assert_equal(ui._config.halSideMap.inputBus, 4, "8.2: inputBus side updated to left")

    -- Test 8.3: Can update interface
    ui._config.halSideMap.interface = 0
    assert_equal(ui._config.halSideMap.interface, 0, "8.3: interface side set to bottom")
end

--===========================================================================
-- Group 9: Config set/get
--===========================================================================
do
    reportGroup("Group 9: Config set/get")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local comp = makeComponents()
    local ConfigUI = require("src.config_ui")
    local ui = ConfigUI.new("/tmp/test.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })

    -- Test 9.1: setConfig/getConfig round-trip
    local testCfg = {
        brokerId = "set-get-test",
        telemetryPort = 1111,
        machines = { "addr1", "addr2" },
        machineTypes = { addr1 = 4, addr2 = 128 },
        pollInterval = 2.5,
    }
    ui:setConfig(testCfg)
    local retrieved = ui:getConfig()
    assert_not_nil(retrieved, "9.1: getConfig returns table")
    assert_equal(retrieved.brokerId, "set-get-test", "9.1: brokerId via getConfig")
    assert_equal(retrieved.telemetryPort, 1111, "9.1: telemetryPort via getConfig")
    assert_equal(#retrieved.machines, 2, "9.1: machine count via getConfig")
end

--===========================================================================
-- Group 10: Low-component/no-OC environment
--===========================================================================
do
    reportGroup("Group 10: Edge cases — nil/invalid inputs")

    local gpu = MockGPU.new()
    local fs = MockFilesystem.new()
    local emptyComp = MockComponent.new({})
    local ConfigUI = require("src.config_ui")

    -- Test 10.1: Constructor with no components at all
    local ui = ConfigUI.new("/tmp/noenv.cfg", {
        gpu = gpu,
        filesystem = fs,
        component = emptyComp,
    })
    assert_not_nil(ui, "10.1: Created with empty component list")

    -- Test 10.2: Detection on empty env returns no components
    local detected = ui:detectComponents()
    assert_not_nil(detected, "10.2: Detection ran on empty env")
    assert_equal(#detected.components, 0, "10.2: Zero components on empty env")
    assert_nil(detected.modem, "10.2: No modem on empty env")
    assert_nil(detected.transposer, "10.2: No transposer on empty env")

    -- Test 10.3: Connectivity test with no component lib
    local uiNoComp = ConfigUI.new("/tmp/nocomp.cfg", {
        gpu = gpu,
        filesystem = fs,
    })
    local ok, msg = uiNoComp:testComponent("some-address", "modem")
    assert_false(ok, "10.3: Test fails without component lib")
    assert_true(#msg > 0, "10.3: Error message returned")

    -- Test 10.4: Save config at default path
    local uiDefPath = ConfigUI.new(nil, {
        gpu = gpu,
        filesystem = fs,
        component = comp,
    })
    assert_equal(uiDefPath._configPath, "/home/ae2es_broker.cfg", "10.4: Default path when nil passed")
end

--===========================================================================
-- Group 11: version constant
--===========================================================================
do
    reportGroup("Group 11: Version constant")

    local ConfigUI = require("src.config_ui")
    assert_not_nil(ConfigUI.VERSION, "11.1: Version constant exists")
    assert_equal(type(ConfigUI.VERSION), "string", "11.2: Version is string")
end

--===========================================================================
-- Summary
--===========================================================================
print("")
print(string.rep("=", 60))
print(string.format("ConfigUI Test Summary: %d passed, %d failed, %d errors",
    test_results.passed, test_results.failed, #test_results.errors))

if #test_results.errors > 0 then
    print("")
    print("Errors:")
    for _, err in ipairs(test_results.errors) do
        print("  " .. err)
    end
end

if test_results.failed > 0 or #test_results.errors > 0 then
    os.exit(1)
else
    os.exit(0)
end
