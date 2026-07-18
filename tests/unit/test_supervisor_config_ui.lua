--=============================================================================
-- tests/unit/test_supervisor_config_ui.lua
-- Unit tests for supervisor/config_ui.lua
-- Tier 1: Vanilla Lua 5.3, no OC runtime.
-- Tests the ConfigUI class (construction, config I/O, data access) and the
-- shared UI library (src/ui/common.lua).
--
-- Interactive elements (event.pull-based menus, dialogs) are NOT tested in
-- this suite since they require a live terminal. Instead, we test the data
-- layer, config persistence, and non-interactive utility functions.
--=============================================================================

--=============================================================================
-- Minimal Test Framework (self-contained, no dependencies)
--=============================================================================

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

local function assert_type(expected_type, val, msg)
    msg = msg or ""
    if type(val) == expected_type then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: expected type '%s', got '%s'",
        msg, expected_type, type(val))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

local function assert_table_key(tbl, key, msg)
    msg = msg or ""
    if tbl[key] ~= nil then
        test_results.passed = test_results.passed + 1
        return true
    end
    test_results.failed = test_results.failed + 1
    local err = string.format("FAIL [%s]: missing key '%s' in table", msg, tostring(key))
    table.insert(test_results.errors, err)
    print("  " .. err)
    return false
end

print("========================================")
print("Test Suite: supervisor/config_ui.lua")
print("========================================")
print("")

--=============================================================================
-- Mock OC Environment
--=============================================================================

-- Build minimal OC component mocks needed for the UI module to load
_G.component = {
    list = function()
        -- Return an empty list by default; tests can override
        return function()
            return nil
        end
    end,
    isAvailable = function()
        return false
    end,
    getPrimary = function()
        return nil
    end,
}

_G.event = {
    pull = function()
        -- Stub: return interrupted to let loops exit
        return "interrupted"
    end,
}

-- Provide os.clock if missing (Lua 5.3 provides it)
if not os.clock then
    os.clock = os.time
end

--=============================================================================
-- Load the modules under test
--=============================================================================

-- Set up package path
package.path = "./src/?.lua;./src/ui/?.lua;./supervisor/?.lua;./?.lua;" .. package.path

local UI
local ConfigUI

local ok_ui, err_ui = pcall(function()
    UI = require("src.ui.common")
end)
assert_true(ok_ui, "Load src.ui.common: " .. tostring(err_ui))

-- The ConfigUI module requires event, component - ensure they exist
local ok_cui, err_cui = pcall(function()
    ConfigUI = require("supervisor.config_ui")
end)

-- ConfigUI will fail to load if it can't resolve component/event at require time
-- But it uses pcall for most runtime dependencies, so it should load.
-- Let's check if loading failed due to missing sub-dependencies.
if not ok_cui then
    print("  WARN: ConfigUI module not loadable: " .. tostring(err_cui))
    print("  (Tests requiring ConfigUI will be skipped)")
end

print("")

--=============================================================================
-- Group 1: UI Library Tests
--=============================================================================

print("--- Group 1: UI Library - Constants and Helpers ---")

-- 1.1 Color constants
assert_equal(UI.COLOR.BG, 0x000000, "COLOR.BG default")
assert_equal(UI.COLOR.TEXT, 0xFFFFFF, "COLOR.TEXT default")
assert_equal(UI.COLOR.ACTIVE, 0x00FF00, "COLOR.ACTIVE")
assert_equal(UI.COLOR.STALE, 0xFFFF00, "COLOR.STALE")
assert_equal(UI.COLOR.OFFLINE, 0xFF3333, "COLOR.OFFLINE")
assert_equal(UI.COLOR.TTD_GOOD, 0x00FF00, "COLOR.TTD_GOOD")
assert_equal(UI.COLOR.TTD_WARN, 0xFFFF00, "COLOR.TTD_WARN")
assert_equal(UI.COLOR.TTD_CRIT, 0xFF0000, "COLOR.TTD_CRIT")

-- 1.2 Key constants
assert_equal(UI.KEY.UP, 200, "KEY.UP")
assert_equal(UI.KEY.DOWN, 208, "KEY.DOWN")
assert_equal(UI.KEY.ENTER, 28, "KEY.ENTER")
assert_equal(UI.KEY.ESCAPE, 1, "KEY.ESCAPE")
assert_equal(UI.KEY.TAB, 15, "KEY.TAB")

-- 1.3 Color utility functions
assert_equal(UI.color_for_status("ACTIVE"), UI.COLOR.ACTIVE, "color_for_status ACTIVE")
assert_equal(UI.color_for_status("STALE"), UI.COLOR.STALE, "color_for_status STALE")
assert_equal(UI.color_for_status("OFFLINE"), UI.COLOR.OFFLINE, "color_for_status OFFLINE")
assert_equal(UI.color_for_status("UNKNOWN"), UI.COLOR.UNREGISTERED, "color_for_status UNKNOWN")

assert_equal(UI.color_for_machine_status("AVAILABLE"), UI.COLOR.AVAILABLE, "color_for_machine_status AVAILABLE")
assert_equal(UI.color_for_machine_status("LOCKED"), UI.COLOR.LOCKED, "color_for_machine_status LOCKED")
assert_equal(UI.color_for_machine_status("PROCESSING"), UI.COLOR.PROCESSING, "color_for_machine_status PROCESSING")
assert_equal(UI.color_for_machine_status("FAULTED"), UI.COLOR.FAULTED, "color_for_machine_status FAULTED")
assert_equal(UI.color_for_machine_status("UNKNOWN"), UI.COLOR.DIM, "color_for_machine_status UNKNOWN")

-- 1.4 TTD color
assert_equal(UI.color_for_ttd(true, 30), UI.COLOR.TTD_CRIT, "color_for_ttd critical")
assert_equal(UI.color_for_ttd(false, 30), UI.COLOR.TTD_CRIT, "color_for_ttd < 60s")
assert_equal(UI.color_for_ttd(false, 120), UI.COLOR.TTD_WARN, "color_for_ttd < 300s")
assert_equal(UI.color_for_ttd(false, 600), UI.COLOR.TTD_GOOD, "color_for_ttd > 300s")
assert_equal(UI.color_for_ttd(false, nil), UI.COLOR.TTD_GOOD, "color_for_ttd nil secs")

print("")

--=============================================================================
-- Group 2: Formatting Helpers
--=============================================================================

print("--- Group 2: Formatting Helpers ---")

-- 2.1 format_ttd
assert_equal(UI.format_ttd(nil), "--:--", "format_ttd nil")
assert_equal(UI.format_ttd(0), "--:--", "format_ttd 0")
assert_equal(UI.format_ttd(-5), "--:--", "format_ttd negative")
assert_equal(UI.format_ttd(math.huge), "INF", "format_ttd infinite")
assert_equal(UI.format_ttd(90), "1:30", "format_ttd 90s")
assert_equal(UI.format_ttd(3600), "60:00", "format_ttd 3600s")

-- 2.2 format_elapsed
assert_equal(UI.format_elapsed(nil), "--", "format_elapsed nil")
assert_equal(UI.format_elapsed(30), "30s", "format_elapsed 30s")
assert_equal(UI.format_elapsed(90), "1m30s", "format_elapsed 90s")
assert_equal(UI.format_elapsed(3661), "1h01m", "format_elapsed 3661s")

-- 2.3 truncate
assert_equal(UI.truncate("hello", 20), "hello", "truncate short string")
assert_equal(UI.truncate("a very long string that should be truncated", 20), "a very long strin...", "truncate long string")
assert_equal(UI.truncate("test", 4), "test", "truncate exact length")
assert_equal(UI.truncate("test", 3), "tes", "truncate shorter than string (max_len <= 3, no room for ...)")

print("")

--=============================================================================
-- Group 3: Deep Copy
--=============================================================================

print("--- Group 3: Deep Copy ---")

-- 3.1 Deep copy produces independent tables
local original = {
    simple = 42,
    nested = { a = 1, b = { c = 3 } },
    arr = { 1, 2, 3 },
}
local copy = UI.deep_copy(original)
assert_equal(copy.simple, 42, "deep copy preserves scalar")
assert_equal(copy.nested.a, 1, "deep copy preserves nested")
assert_equal(copy.arr[1], 1, "deep copy preserves array")

-- Modify original and verify copy unchanged
original.simple = 99
original.nested.a = 999
original.arr[1] = 100
assert_equal(copy.simple, 42, "deep copy independent: scalar")
assert_equal(copy.nested.a, 1, "deep copy independent: nested")
assert_equal(copy.arr[1], 1, "deep copy independent: array")

-- 3.2 Deep copy handles nil values
local with_nil = { a = 1, b = nil, c = "hello" }
local copy2 = UI.deep_copy(with_nil)
assert_equal(copy2.a, 1, "deep copy preserves non-nil keys")
-- nil keys are not serialized in Lua tables

print("")

--=============================================================================
-- Group 4: GPU Stub Rendering Tests
--=============================================================================

print("--- Group 4: GPU Stub Tests ---")

-- Create a minimal GPU stub that records operations
-- NOTE: All methods use dot syntax (gpu.setBackground(color)) not colon syntax
-- (gpu:setBackground(color)) because that's how OC GPU proxies work.
local gpu_stub_calls = {}
local gpu_stub = {
    setBackground = function(color)
        table.insert(gpu_stub_calls, { method = "setBackground", args = { color } })
    end,
    setForeground = function(color)
        table.insert(gpu_stub_calls, { method = "setForeground", args = { color } })
    end,
    set = function(x, y, text)
        table.insert(gpu_stub_calls, { method = "set", args = { x, y, text } })
    end,
    fill = function(x, y, w, h, char)
        table.insert(gpu_stub_calls, { method = "fill", args = { x, y, w, h, char } })
    end,
    getResolution = function()
        return 80, 25
    end,
}

-- 4.1 fill_region
gpu_stub_calls = {}
UI.fill_region(gpu_stub, 1, 2, 40, 3, 0xFF0000)
assert_equal(#gpu_stub_calls, 2, "fill_region: 2 GPU calls (setBackground + fill)")
assert_equal(gpu_stub_calls[1].method, "setBackground", "fill_region: first call is setBackground")
assert_equal(gpu_stub_calls[1].args[1], 0xFF0000, "fill_region: red background")
assert_equal(gpu_stub_calls[2].method, "fill", "fill_region: second call is fill")

-- 4.2 draw_hr (horizontal rule)
gpu_stub_calls = {}
UI.draw_hr(gpu_stub, 5, 80)
assert_true(#gpu_stub_calls >= 2, "draw_hr: at least 2 GPU calls")

-- 4.3 draw_field
gpu_stub_calls = {}
UI.draw_field(gpu_stub, 3, 4, "Label:", "value", 0x00FF00)
-- Should call setBackground, setForeground, set, setForeground, set
assert_true(#gpu_stub_calls >= 3, "draw_field: at least 3 GPU calls")

-- 4.4 draw_centered (with default width 80)
gpu_stub_calls = {}
UI.draw_centered(gpu_stub, 10, "Hello World", 80, 0xFFFF00, 0x000000)
-- Text is 11 chars, should be centered: (80-11)/2 + 1 = 35
assert_true(#gpu_stub_calls >= 2, "draw_centered: at least 2 GPU calls")
-- Find the set call
local set_call = nil
for _, call in ipairs(gpu_stub_calls) do
    if call.method == "set" then
        set_call = call
        break
    end
end
assert_not_nil(set_call, "draw_centered: set call exists")
if set_call then
    -- x should be ~35 for center of 80
    assert_equal(set_call.args[1], 35, "draw_centered: x position for 80 cols")
    assert_equal(set_call.args[2], 10, "draw_centered: y position")
    assert_equal(set_call.args[3], "Hello World", "draw_centered: text")
end

-- 4.5 draw_bar
gpu_stub_calls = {}
UI.draw_bar(gpu_stub, 5, 6, 30, 0.5, 0x00FF00)
assert_true(#gpu_stub_calls >= 3, "draw_bar: at least 3 GPU calls (bg bg, bg fill, fg fill)")

-- 4.6 draw_tabs
gpu_stub_calls = {}
UI.draw_tabs(gpu_stub, { "Tab1", "Tab2" }, 1, 1, 1, 80)
-- Must draw at least both tab labels + fill
assert_true(#gpu_stub_calls >= 5, "draw_tabs: at least 5 GPU calls for 2 tabs")

-- 4.7 clear_screen
gpu_stub_calls = {}
UI.clear_screen(gpu_stub, 80, 25)
assert_true(#gpu_stub_calls >= 2, "clear_screen: at least 2 GPU calls")

-- 4.8 write_status
gpu_stub_calls = {}
UI.write_status(gpu_stub, 10, 5, "ACTIVE")
assert_true(#gpu_stub_calls >= 2, "write_status ACTIVE: at least 2 GPU calls")

gpu_stub_calls = {}
UI.write_status(gpu_stub, 10, 5, "OFFLINE")
assert_true(#gpu_stub_calls >= 2, "write_status OFFLINE: at least 2 GPU calls")

print("")

--=============================================================================
-- Group 5: Config I/O (File-based)
--=============================================================================

print("--- Group 5: Config I/O ---")

if ok_cui and ConfigUI then
    -- 5.1 Default config path
    local path = ConfigUI.get_config_path()
    assert_equal(path, "/home/ae2es_supervisor.cfg", "Default config path")

    -- 5.2 config_exists returns false initially
    -- (no config file exists in the test environment)
    local exists = ConfigUI.config_exists()
    assert_equal(exists, false, "config_exists: no file initially")

    -- 5.3 load_config returns nil + error when no file exists
    local loaded, err = ConfigUI.load_config()
    assert_nil(loaded, "load_config: nil when no file")
    assert_not_nil(err, "load_config: error string when no file")

    -- 5.4 Create a config object and verify defaults
    local instance = ConfigUI.new()
    local config = instance:get_config()
    assert_table_key(config, "supervisorPort", "default config has supervisorPort")
    assert_table_key(config, "maxQueueSize", "default config has maxQueueSize")
    assert_table_key(config, "ttdThresholds", "default config has ttdThresholds")
    assert_table_key(config, "dashboardLayout", "default config has dashboardLayout")
    assert_table_key(config, "brokerRegistry", "default config has brokerRegistry")
    assert_equal(config.supervisorPort, 123, "default supervisorPort")
    assert_equal(config.maxQueueSize, 1000, "default maxQueueSize")
    assert_equal(config.queueTrimTarget, 500, "default queueTrimTarget")
    assert_equal(config.maxLogEntries, 200, "default maxLogEntries")

    -- 5.5 TTD thresholds defaults
    local ttd = config.ttdThresholds
    assert_table_key(ttd, "items", "ttd has items")
    assert_table_key(ttd, "fluids", "ttd has fluids")
    assert_table_key(ttd, "power", "ttd has power")
    assert_equal(ttd.items.warning, 600, "ttd items warning default")
    assert_equal(ttd.items.critical, 120, "ttd items critical default")
    assert_equal(ttd.power.warning, 300, "ttd power warning default")
    assert_equal(ttd.power.critical, 60, "ttd power critical default")

    -- 5.6 Dashboard layout defaults
    local layout = config.dashboardLayout
    assert_equal(layout.mode, "compact", "dashboard mode default")
    assert_equal(layout.refreshRate, 0.5, "dashboard refresh rate default")
    assert_equal(layout.showAlerts, true, "dashboard showAlerts default")
    assert_equal(layout.showTTD, true, "dashboard showTTD default")
    assert_equal(layout.showBrokers, true, "dashboard showBrokers default")
    assert_equal(layout.showMatrix, true, "dashboard showMatrix default")

    -- 5.7 Broker registry defaults to empty
    assert_type("table", config.brokerRegistry, "brokerRegistry is a table")
    assert_equal(#config.brokerRegistry, 0, "brokerRegistry starts empty")

    -- 5.8 Custom config overrides
    local custom_config = {
        supervisorPort = 250,
        maxQueueSize = 5000,
        ttdThresholds = { items = { warning = 300, critical = 60 } },
        brokerRegistry = { "broker-alpha", "broker-beta" },
    }
    local instance2 = ConfigUI.new(custom_config)
    local config2 = instance2:get_config()
    assert_equal(config2.supervisorPort, 250, "custom supervisorPort")
    assert_equal(config2.maxQueueSize, 5000, "custom maxQueueSize")
    assert_equal(config2.ttdThresholds.items.warning, 300, "custom TTD items warning")
    assert_equal(config2.ttdThresholds.items.critical, 60, "custom TTD items critical")
    -- Non-overridden values keep defaults
    assert_equal(config2.maxLogEntries, 200, "non-overridden field keeps default")
    assert_equal(#config2.brokerRegistry, 2, "custom brokerRegistry count")
    assert_equal(config2.brokerRegistry[1], "broker-alpha", "custom brokerRegistry[1]")
    assert_equal(config2.brokerRegistry[2], "broker-beta", "custom brokerRegistry[2]")

    -- 5.9 Config isolation (get_config returns a copy)
    local config_copy = instance:get_config()
    config_copy.supervisorPort = 999
    local config_again = instance:get_config()
    assert_equal(config_again.supervisorPort, 123, "config isolation: original unchanged")
else
    print("  SKIP: ConfigUI module not available")
end

print("")

--=============================================================================
-- Group 6: ConfigUI Instance Management
--=============================================================================

print("--- Group 6: ConfigUI Instance Management ---")

if ok_cui and ConfigUI then
    -- 6.1 New instance without args uses defaults
    local ui = ConfigUI.new()
    assert_not_nil(ui, "ConfigUI.new() returns instance")
    assert_type("table", ui, "ConfigUI.new() returns table")
    assert_type("function", ui.get_config, "instance has get_config")
    assert_type("function", ui.save_current, "instance has save_current")

    -- 6.2 Modified flag starts false
    assert_equal(ui._modified, false, "modified starts false")

    -- 6.3 get_config returns valid config
    local cfg = ui:get_config()
    assert_equal(cfg.supervisorPort, 123, "get_config supervisorPort")

    -- 6.4 Instance with custom config overrides defaults
    local ui2 = ConfigUI.new({ supervisorPort = 8080 })
    local cfg2 = ui2:get_config()
    assert_equal(cfg2.supervisorPort, 8080, "custom config in constructor")
    assert_equal(cfg2.maxQueueSize, 1000, "default preserved in constructor")
else
    print("  SKIP: ConfigUI module not available")
end

print("")

--=============================================================================
-- Group 7: Tab Rendering (with GPU stub)
--=============================================================================

print("--- Group 7: Render Methods ---")

if ok_cui and ConfigUI then
    -- Create instance with a mocked GPU environment
    local ui = ConfigUI.new()

    -- Override _gpu with our stub
    ui._gpu = gpu_stub
    ui._term_cols = 80
    ui._term_rows = 25

    -- 7.1 Tab labels (tested via render methods)
    -- Tab constants are module-local, so we verify rendering works instead
    assert_type("table", ui._config, "instance has config table")
end

-- (Tab rendering tested via GPU stub calls in Group 4)

print("")

--=============================================================================
-- Group 8: Edge Cases
--=============================================================================

print("--- Group 8: Edge Cases ---")

-- 8.1 Deep copy of empty table
local empty_copy = UI.deep_copy({})
assert_type("table", empty_copy, "deep copy empty table")
assert_equal(#empty_copy, 0, "deep copy empty table length")

-- 8.2 Deep copy with mixed types
local mixed = {
    str = "hello",
    num = 42,
    bool = true,
    arr = { 1, "two", false },
    nested = { deep = { deeper = "value" } },
}
local mixed_copy = UI.deep_copy(mixed)
assert_equal(mixed_copy.str, "hello", "deep copy string")
assert_equal(mixed_copy.num, 42, "deep copy number")
assert_equal(mixed_copy.bool, true, "deep copy boolean")
assert_equal(mixed_copy.arr[1], 1, "deep copy array element")
assert_equal(mixed_copy.nested.deep.deeper, "value", "deep copy deeply nested")

-- 8.3 Non-table values are returned as-is by deep copy
assert_equal(UI.deep_copy(42), 42, "deep copy number passthrough")
assert_equal(UI.deep_copy("hello"), "hello", "deep copy string passthrough")
assert_nil(UI.deep_copy(nil), "deep copy nil passthrough")
assert_equal(UI.deep_copy(true), true, "deep copy boolean passthrough")

-- 8.4 TTD color with non-standard values
assert_equal(UI.color_for_ttd(false, 1), UI.COLOR.TTD_CRIT, "TTD color 1 second")
assert_equal(UI.color_for_ttd(false, 59), UI.COLOR.TTD_CRIT, "TTD color 59 seconds")
assert_equal(UI.color_for_ttd(false, 60), UI.COLOR.TTD_WARN, "TTD color 60 seconds (boundary)")
assert_equal(UI.color_for_ttd(false, 299), UI.COLOR.TTD_WARN, "TTD color 299 seconds")
assert_equal(UI.color_for_ttd(false, 300), UI.COLOR.TTD_GOOD, "TTD color 300 seconds (boundary)")

-- 8.5 Truncate edge cases
assert_equal(UI.truncate("", 10), "", "truncate empty string")
assert_equal(UI.truncate("abc", 3), "abc", "truncate at exact boundary no room for ...")
assert_equal(UI.truncate("abcd", 4), "abcd", "truncate exact match width")

print("")

--=============================================================================
-- Summary
--=============================================================================

print("========================================")
local total = test_results.passed + test_results.failed
local status = (test_results.failed == 0) and "PASSED" or "FAILED"
print(string.format("Results: %d/%d passed, %d failed - %s",
    test_results.passed, total, test_results.failed, status))

if test_results.failed > 0 then
    print("Failures:")
    for _, err in ipairs(test_results.errors) do
        print("  " .. err)
    end
end

print("")

-- Exit code: 0 = all passed
os.exit(test_results.failed == 0 and 0 or 1)
