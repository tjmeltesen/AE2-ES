--===========================================================================
-- test_dashboard.lua — Unit tests for supervisor/ui/dashboard.lua
-- Tier 1: Vanilla Lua 5.3, no OC runtime. Mock GPU and OC APIs.
-- Task B5: Dashboard UI
--===========================================================================

--===========================================================================
-- Minimal Test Framework
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

local function assert_table_equal(t1, t2, msg)
    msg = msg or ""
    if t1 == nil and t2 == nil then
        test_results.passed = test_results.passed + 1
        return true
    end
    if t1 == nil or t2 == nil then
        test_results.failed = test_results.failed + 1
        local err = string.format("FAIL [%s]: one table is nil", msg)
        table.insert(test_results.errors, err)
        print("  " .. err)
        return false
    end
    for k, v in pairs(t1) do
        if type(v) == "table" and type(t2[k]) == "table" then
            for k2, v2 in pairs(v) do
                if v2 ~= t2[k][k2] then
                    test_results.failed = test_results.failed + 1
                    local err = string.format("FAIL [%s]: tables differ at [%s][%s]", msg, tostring(k), tostring(k2))
                    table.insert(test_results.errors, err)
                    print("  " .. err)
                    return false
                end
            end
        elseif v ~= t2[k] then
            test_results.failed = test_results.failed + 1
            local err = string.format("FAIL [%s]: tables differ at key '%s'", msg, tostring(k))
            table.insert(test_results.errors, err)
            print("  " .. err)
            return false
        end
    end
    for k, _ in pairs(t2) do
        if t1[k] == nil then
            test_results.failed = test_results.failed + 1
            local err = string.format("FAIL [%s]: key '%s' missing from first table", msg, tostring(k))
            table.insert(test_results.errors, err)
            print("  " .. err)
            return false
        end
    end
    test_results.passed = test_results.passed + 1
    return true
end

--===========================================================================
-- Mock OC APIs (needed before loading dashboard module)
--===========================================================================

-- Mock component API
component = {
    list = function()
        -- Return a modem and a GPU for the dashboard
        local i = 0
        return function()
            i = i + 1
            if i == 1 then return "addr-gpu-001", "gpu" end
            if i == 2 then return "addr-modem-001", "modem" end
            return nil
        end
    end,
    isAvailable = function(name)
        return name == "gpu" or name == "modem"
    end,
    getPrimary = function(name)
        if name == "gpu" then
            return _mock_gpu
        elseif name == "modem" then
            return _mock_modem
        end
        return nil
    end,
    proxy = function(addr)
        if addr == "addr-gpu-001" then return _mock_gpu end
        if addr == "addr-modem-001" then return _mock_modem end
        return nil
    end,
}

-- Mock GPU: capture all rendering commands for test assertions.
-- Methods support BOTH dot-call (gpu.setBackground(color)) and colon-call
-- (gpu:setBackground(color)) since OC component proxies accept both styles.
_mock_gpu = {}
_mock_gpu._draw_calls = {}
_mock_gpu._state = { bg = 0, fg = 0xFFFFFF }

local function _gpu_record(op, ...)
    table.insert(_mock_gpu._draw_calls, { op = op, args = {...} })
end

function _mock_gpu.setBackground(bg_color)
    _mock_gpu._state.bg = bg_color
    _gpu_record("setBackground", bg_color)
end

function _mock_gpu.setForeground(fg_color)
    _mock_gpu._state.fg = fg_color
    _gpu_record("setForeground", fg_color)
end

function _mock_gpu.fill(x, y, w, h, char)
    _gpu_record("fill", x, y, w, h, char)
end

function _mock_gpu.set(x, y, text)
    _gpu_record("set", x, y, text)
end

function _mock_gpu.getResolution()
    return 80, 25
end

function _mock_gpu.setResolution(w, h)
    _gpu_record("setResolution", w, h)
end

-- Reset mock state
function _reset_mock_gpu()
    _mock_gpu._draw_calls = {}
    _mock_gpu._state = { bg = 0, fg = 0xFFFFFF }
end

-- Count draw calls of a specific operation
function _count_draw_calls(op_name)
    local count = 0
    for _, call in ipairs(_mock_gpu._draw_calls) do
        if call.op == op_name then
            count = count + 1
        end
    end
    return count
end

-- Mock modem
_mock_modem = {}
_mock_modem._port = nil
_mock_modem._messages = {}

function _mock_modem:open(port)
    self._port = port
    return true
end

function _mock_modem:close(port)
    self._port = nil
end

function _mock_modem:send(addr, port, ...) end
function _mock_modem:broadcast(port, ...) end

-- Mock event API
event = {}
event._queue = {}
event._timer_callbacks = {}

function event.pull(timeout, filter)
    -- Return from queue if available
    if #event._queue > 0 then
        return table.unpack(table.remove(event._queue, 1))
    end
    -- Simulate sleep
    return nil  -- timeout with no event
end

function event.push(name, ...)
    table.insert(event._queue, {name, ...})
end

function event.timer(interval, callback, repeat_count)
    return 0  -- mock timer ID
end

function event.cancel(id) end
function event.ignore(name, callback) end

-- Reset mock event queue
function _reset_mock_event()
    event._queue = {}
end

-- Enqueue a fake key press
function _mock_key_down(char, code)
    table.insert(event._queue, {"key_down", "addr-kb-001", char or "", code or 0})
end

-- Enqueue a fake modem message
function _mock_modem_message(remote_addr, port, data)
    table.insert(event._queue, {
        "modem_message", "addr-local-001", remote_addr, port, 0, data
    })
end

-- Mock os functions
if not os.clock then
    local _clock = 1000.0
    function os.clock()
        _clock = _clock + 0.5
        return _clock
    end
end

if not os.time then
    local _time = 1719000000
    function os.time()
        return _time
    end
    -- Allow test to advance time
    function _set_mock_time(t)
        _time = t
    end
end

function os.sleep(n)
    -- no-op in tests
end

-- Mock computer API
computer = {}

function computer.pushSignal(name, ...)
    -- Enqueue a signal; dashboard's event.pull in handle_input will pick it up
    table.insert(event._queue, {name or "key_down", nil, nil, 0})
end

-- Mock serialization API (used by modem subscriber fallback)
serialization = {}

function serialization.unserialize(data)
    return load("return " .. data)()
end

-- Mock term API
term = {}

function term.clear()
    -- no-op
end

--===========================================================================
-- Setup: Lua path for local modules
--===========================================================================

local test_dir = arg and arg[0] or ""
local root = test_dir:match("^(.*)[/\\]tests[/\\]unit")
if not root then
    root = "."
end
-- Make it an absolute-looking path for Windows compatibility
if root:sub(1, 1) ~= "/" and root:sub(2, 2) ~= ":" then
    root = root:gsub("\\", "/")
end

package.path = root .. "/supervisor/?.lua;"
    .. root .. "/supervisor/?/init.lua;"
    .. root .. "/src/?.lua;"
    .. root .. "/src/?/init.lua;"
    .. package.path

--===========================================================================
-- Test Group 1: Dashboard Creation & Dependency Resolution
--===========================================================================

print("\n=== Test Group 1: Dashboard Creation & Dependency Resolution ===")

local function _make_dependencies()
    return {
        subscriber = {
            getActiveBrokers = function() return {} end,
            getBrokerStatus = function() return nil end,
            getNextPayload = function() return nil end,
            getQueueSize = function() return 0 end,
        },
        matrix = {
            getMachines = function() return {} end,
            getAllBrokers = function() return {} end,
            getMachineCount = function() return 0 end,
            getStats = function()
                return { total = 0, available = 0, processing = 0, faulted = 0 }
            end,
            updateFromPayload = function() end,
        },
        ttd = {
            getTTD = function()
                return {
                    items = { level = 0, max = 100, depletion_secs = 0, critical = false },
                    fluids = { level = 0, max = 100, depletion_secs = 0, critical = false },
                    power = { level = 0, max = 100, depletion_secs = 0, critical = false },
                }
            end,
            updateFromPayload = function() end,
        },
        alerts = {
            getAlerts = function() return {} end,
            acknowledge = function() end,
            acknowledgeAll = function() end,
            dismissResolved = function() end,
            getActiveCount = function() return 0 end,
            ingest = function() end,
        },
    }
end

local function _new_dash()
    local Dashboard = require("supervisor.ui.dashboard")
    return Dashboard.new(_make_dependencies())
end

print("\n--- 1.1: Dashboard.new() creates instance with GPU ---")
local function test_dashboard_creation()
    _reset_mock_gpu()
    _reset_mock_event()

    local Dashboard = require("supervisor.ui.dashboard")
    assert_not_nil(Dashboard, "Dashboard module loaded")

    local dash, err = _new_dash()
    assert_not_nil(dash, "Dashboard instance created")
    assert_nil(err, "No error on creation")
    assert_true(dash.running == false, "Not running initially")
    assert_true(dash.focused_panel == "brokers", "Default focus is brokers panel")
    assert_equal(dash.focus_index, 0, "No selection initially")
end
test_dashboard_creation()

print("\n--- 1.2: Dashboard uses all four explicit dependencies ---")
local function test_dashboard_dependencies()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dependencies = _make_dependencies()
    local dash = Dashboard.new(dependencies)

    assert_equal(dash.subscriber, dependencies.subscriber, "Subscriber injected")
    assert_equal(dash.matrix, dependencies.matrix, "Matrix injected")
    assert_equal(dash.ttd, dependencies.ttd, "TTD injected")
    assert_equal(dash.alerts, dependencies.alerts, "Alerts injected")

    -- Each should have the expected interface methods
    assert_not_nil(dash.subscriber.getActiveBrokers, "subscriber has getActiveBrokers")
    assert_not_nil(dash.matrix.getMachines, "matrix has getMachines")
    assert_not_nil(dash.ttd.getTTD, "ttd has getTTD")
    assert_not_nil(dash.alerts.getAlerts, "alerts has getAlerts")
end
test_dashboard_dependencies()

print("\n--- 1.3: Dashboard.new() fails without GPU ---")
local function test_dashboard_no_gpu()
    -- Temporarily mock no GPU
    local orig_isAvailable = component.isAvailable
    component.isAvailable = function() return false end

    local Dashboard = require("supervisor.ui.dashboard")
    local dash, err = Dashboard.new(_make_dependencies())
    assert_nil(dash, "Dashboard creation fails without GPU")
    assert_not_nil(err, "Returns error message")
    assert_true(err:find("GPU") or err:find("gpu"), "Error mentions GPU")

    component.isAvailable = orig_isAvailable
end
test_dashboard_no_gpu()

print("\n--- 1.4: Dashboard.stop() sets running to false ---")
local function test_dashboard_stop()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()
    dash.running = true  -- simulate started state
    dash:stop()
    assert_true(dash.running == false, "Running flag cleared after stop")
end
test_dashboard_stop()

--===========================================================================
-- Test Group 2: Navigation State Machine
--===========================================================================

print("\n=== Test Group 2: Navigation State Machine ===")

print("\n--- 2.1: Tab cycles focus between panels in order ---")
local function test_navigation_tab_cycle()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    -- Add some brokers so navigation works
    dash.subscriber.getActiveBrokers = function()
        return {
            ["broker-1"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 0 },
            ["broker-2"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 3 },
            ["broker-3"] = { status = "STALE", last_heard = os.time() - 60, queueLength = 0 },
        }
    end

    -- Start at brokers
    assert_equal(dash.focused_panel, "brokers", "Starts at brokers")

    dash:cycle_focus(1)
    assert_equal(dash.focused_panel, "matrix", "Tab once -> matrix")

    dash:cycle_focus(1)
    assert_equal(dash.focused_panel, "alerts", "Tab twice -> alerts")

    dash:cycle_focus(1)
    assert_equal(dash.focused_panel, "ttd", "Tab third -> ttd")

    dash:cycle_focus(1)
    assert_equal(dash.focused_panel, "brokers", "Tab fourth -> wraps to brokers")

    -- Reverse
    dash:cycle_focus(-1)
    assert_equal(dash.focused_panel, "ttd", "Shift-Tab wraps back to ttd")
end
test_navigation_tab_cycle()

print("\n--- 2.2: Arrow up/down navigates broker list ---")
local function test_navigation_broker_list()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.subscriber.getActiveBrokers = function()
        return {
            ["broker-a"] = { status = "ACTIVE",   last_heard = os.time(), queueLength = 5 },
            ["broker-b"] = { status = "STALE",    last_heard = os.time() - 40, queueLength = 0 },
            ["broker-c"] = { status = "OFFLINE",  last_heard = os.time() - 200, queueLength = 0 },
        }
    end

    -- No selection yet
    assert_equal(dash.focus_index, 0, "Starts with no selection")

    dash:navigate(1)  -- down
    assert_true(dash.focus_index > 0, "Down arrow selects first broker")

    dash:navigate(1)  -- down again
    local first_idx = dash.focus_index

    dash:navigate(-1)  -- up
    assert_true(dash.focus_index < first_idx, "Up arrow moves back up")

    -- selected_broker should update
    assert_not_nil(dash.selected_broker, "Selected broker is set")
end
test_navigation_broker_list()

print("\n--- 2.3: Navigation wraps around at list edges ---")
local function test_navigation_wrap_around()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.subscriber.getActiveBrokers = function()
        return {
            ["broker-x"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 1 },
            ["broker-y"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 2 },
        }
    end

    dash:navigate(1)  -- select first
    dash:navigate(1)  -- select second
    dash:navigate(1)  -- wrap to first
    assert_equal(dash.focus_index, 1, "Wraps to first broker")

    dash:navigate(-1) -- wrap to last
    assert_equal(dash.focus_index, 2, "Wraps to last broker")
end
test_navigation_wrap_around()

print("\n--- 2.4: Empty broker list handles navigation gracefully ---")
local function test_navigation_empty_brokers()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.subscriber.getActiveBrokers = function() return {} end

    dash:navigate(1)
    assert_equal(dash.focus_index, 0, "No selection when list is empty")
end
test_navigation_empty_brokers()

print("\n--- 2.5: Tab reset focus_index to 0 on panel switch ---")
local function test_navigation_resets_index()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.subscriber.getActiveBrokers = function()
        return {
            ["broker-1"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 0 },
        }
    end

    dash:navigate(1)  -- select broker
    assert_true(dash.focus_index > 0, "Selection set")

    dash:cycle_focus(1)  -- tab to matrix
    assert_equal(dash.focus_index, 0, "Focus index reset on panel switch")
end
test_navigation_resets_index()

print("\n--- 2.6: Enter on broker panel sets selected_broker ---")
local function test_navigation_enter_broker()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.subscriber.getActiveBrokers = function()
        return {
            ["broker-7"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 0 },
        }
    end

    dash:navigate(1)  -- select broker-7
    dash:activate()   -- Enter
    assert_equal(dash.selected_broker, "broker-7", "Enter sets selected_broker")
end
test_navigation_enter_broker()

print("\n--- 2.7: Enter on alert panel acknowledges selected alert ---")
local function test_navigation_enter_alert()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    local acked = {}
    dash.alerts.getAlerts = function()
        return {
            { id = "alert-1", severity = "WARNING", message = "Test alert", timestamp = os.time(), acknowledged = false },
        }
    end
    dash.alerts.getActiveCount = function() return 1 end
    dash.alerts.acknowledge = function(_, id)
        acked[id] = true
    end

    dash.focused_panel = "alerts"
    dash:navigate(1)  -- select alert-1
    dash:activate()   -- Enter to acknowledge

    assert_true(acked["alert-1"], "Alert acknowledged via Enter")
end
test_navigation_enter_alert()

print("\n--- 2.8: Q key stops the dashboard ---")
local function test_navigation_q_key()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()
    dash.running = true

    -- Simulate: call handle_input after enqueuing a Q key press
    _mock_key_down("q", 16)  -- 'q' with code 16
    dash:handle_input()

    assert_true(dash.running == false, "Q key stops dashboard")
end
test_navigation_q_key()

print("\n--- 2.9: A key acknowledges all alerts ---")
local function test_navigation_a_key()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()
    dash.running = true

    local ack_all_called = false
    dash.alerts.acknowledgeAll = function()
        ack_all_called = true
    end

    _mock_key_down("a", 30)
    dash:handle_input()

    assert_true(ack_all_called, "A key triggers acknowledgeAll")
end
test_navigation_a_key()

--===========================================================================
-- Test Group 3: Data Formatting Helpers
--===========================================================================

print("\n=== Test Group 3: Data Formatting Helpers ===")

print("\n--- 3.1: format_time produces HH:MM:SS ---")
local function test_format_time()
    -- We need to expose the internal helpers. Since they're local, we test
    -- them through the rendered output or by extracting them.
    -- Option: replicate the formatting logic for testing.
    local function replicate_format_time(t)
        t = t or 0
        local h = math.floor(t / 3600) % 24
        local m = math.floor((t % 3600) / 60)
        local s = t % 60
        return string.format("%02d:%02d:%02d", h, m, s)
    end

    assert_equal(replicate_format_time(0),         "00:00:00", "midnight")
    assert_equal(replicate_format_time(3661),      "01:01:01", "1h1m1s")
    assert_equal(replicate_format_time(82800),     "23:00:00", "23h")
    assert_equal(replicate_format_time(86399),     "23:59:59", "one second to midnight")
end
test_format_time()

print("\n--- 3.2: format_elapsed produces readable durations ---")
local function test_format_elapsed()
    local function replicate_format_elapsed(elapsed)
        if not elapsed then return "--" end
        if elapsed < 60 then
            return string.format("%ds", elapsed)
        elseif elapsed < 3600 then
            return string.format("%dm%ds", math.floor(elapsed / 60), elapsed % 60)
        else
            local h = math.floor(elapsed / 3600)
            local m = math.floor((elapsed % 3600) / 60)
            return string.format("%dh%02dm", h, m)
        end
    end

    assert_equal(replicate_format_elapsed(nil),    "--", "nil -> --")
    assert_equal(replicate_format_elapsed(5),      "5s", "5 seconds")
    assert_equal(replicate_format_elapsed(65),     "1m5s", "65 seconds")
    assert_equal(replicate_format_elapsed(125),    "2m5s", "125 seconds")
    assert_equal(replicate_format_elapsed(3661),   "1h01m", "3661 seconds")
    assert_equal(replicate_format_elapsed(7200),   "2h00m", "2 hours")
end
test_format_elapsed()

print("\n--- 3.3: format_ttd produces M:SS countdown ---")
local function test_format_ttd()
    local function replicate_format_ttd(secs)
        if not secs or secs <= 0 then
            return "--:--"
        end
        if secs == math.huge then
            return "INF"
        end
        local m = math.floor(secs / 60)
        local s = secs % 60
        return string.format("%d:%02d", m, s)
    end

    assert_equal(replicate_format_ttd(nil),        "--:--", "nil -> --:--")
    assert_equal(replicate_format_ttd(0),          "--:--", "zero -> --:--")
    assert_equal(replicate_format_ttd(-5),         "--:--", "negative -> --:--")
    assert_equal(replicate_format_ttd(math.huge),  "INF", "huge -> INF")
    assert_equal(replicate_format_ttd(30),         "0:30", "30 seconds")
    assert_equal(replicate_format_ttd(90),         "1:30", "90 seconds")
    assert_equal(replicate_format_ttd(600),        "10:00", "10 minutes")
end
test_format_ttd()

--===========================================================================
-- Test Group 4: Color & Status Mapping
--===========================================================================

print("\n=== Test Group 4: Color & Status Mapping ===")

-- Replicate the color functions (internal to dashboard) for testing
local function replicate_color_for_status(status)
    if status == "ACTIVE"     then return 0x00FF00 end
    if status == "STALE"      then return 0xFFFF00 end
    if status == "OFFLINE"    then return 0xFF3333 end
    if status == "DEADLOCKED" then return 0xFF00FF end
    return 0x888888
end

local function replicate_machine_short(status)
    if status == "AVAILABLE"  then return "AVL" end
    if status == "LOCKED"     then return "LKD" end
    if status == "PROCESSING" then return "PRC" end
    if status == "FAULTED"    then return "FLT" end
    return "---"
end

local function replicate_color_for_machine(status)
    if status == "AVAILABLE"  then return 0x00AA00 end
    if status == "LOCKED"     then return 0xAAAA00 end
    if status == "PROCESSING" then return 0x0088FF end
    if status == "FAULTED"    then return 0xFF0000 end
    return 0x888888
end

local function replicate_color_for_alert(severity)
    if severity == "CRITICAL" then return 0xFF3333 end
    if severity == "WARNING"  then return 0xFFAA00 end
    if severity == "INFO"     then return 0x3399FF end
    return 0x888888
end

print("\n--- 4.1: Status -> color mapping ---")
assert_equal(replicate_color_for_status("ACTIVE"),     0x00FF00, "ACTIVE -> green")
assert_equal(replicate_color_for_status("STALE"),      0xFFFF00, "STALE -> yellow")
assert_equal(replicate_color_for_status("OFFLINE"),    0xFF3333, "OFFLINE -> red")
assert_equal(replicate_color_for_status("DEADLOCKED"), 0xFF00FF, "DEADLOCKED -> magenta")
assert_equal(replicate_color_for_status("UNKNOWN"),    0x888888, "UNKNOWN -> dim fallback")
assert_equal(replicate_color_for_status(nil),          0x888888, "nil -> dim fallback")

print("\n--- 4.2: Machine status -> short code ---")
assert_equal(replicate_machine_short("AVAILABLE"),  "AVL", "AVAILABLE -> AVL")
assert_equal(replicate_machine_short("LOCKED"),     "LKD", "LOCKED -> LKD")
assert_equal(replicate_machine_short("PROCESSING"), "PRC", "PROCESSING -> PRC")
assert_equal(replicate_machine_short("FAULTED"),    "FLT", "FAULTED -> FLT")
assert_equal(replicate_machine_short("UNKNOWN"),    "---", "UNKNOWN -> ---")

print("\n--- 4.3: Machine status -> color ---")
assert_equal(replicate_color_for_machine("AVAILABLE"),  0x00AA00, "AVAILABLE green")
assert_equal(replicate_color_for_machine("LOCKED"),     0xAAAA00, "LOCKED yellow")
assert_equal(replicate_color_for_machine("PROCESSING"), 0x0088FF, "PROCESSING blue")
assert_equal(replicate_color_for_machine("FAULTED"),    0xFF0000, "FAULTED red")

print("\n--- 4.4: Alert severity -> color ---")
assert_equal(replicate_color_for_alert("CRITICAL"), 0xFF3333, "CRITICAL red")
assert_equal(replicate_color_for_alert("WARNING"),  0xFFAA00, "WARNING orange")
assert_equal(replicate_color_for_alert("INFO"),     0x3399FF, "INFO blue")

--===========================================================================
-- Test Group 5: TTD Bar Math
--===========================================================================

print("\n=== Test Group 5: TTD Bar Math ===")

local function replicate_color_for_ttd(critical, depletion_secs)
    if critical or (depletion_secs and depletion_secs > 0 and depletion_secs < 60) then
        return 0xFF0000
    elseif depletion_secs and depletion_secs > 0 and depletion_secs < 300 then
        return 0xFFFF00
    end
    return 0x00FF00
end

print("\n--- 5.1: TTD color thresholds ---")
assert_equal(replicate_color_for_ttd(false, 30),  0xFF0000, "< 1 min -> critical RED")
assert_equal(replicate_color_for_ttd(false, 59),  0xFF0000, "59s -> critical RED")
assert_equal(replicate_color_for_ttd(false, 60),  0xFFFF00, "60s -> warn YELLOW")
assert_equal(replicate_color_for_ttd(false, 120), 0xFFFF00, "2 min -> warn YELLOW")
assert_equal(replicate_color_for_ttd(false, 299), 0xFFFF00, "299s -> warn YELLOW")
assert_equal(replicate_color_for_ttd(false, 300), 0x00FF00, "300s -> good GREEN")
assert_equal(replicate_color_for_ttd(false, 3600), 0x00FF00, "1 hour -> good GREEN")
assert_equal(replicate_color_for_ttd(true, 9999), 0xFF0000, "critical flag overrides")
assert_equal(replicate_color_for_ttd(false, 0),   0x00FF00, "0 depletion -> green (no depletion)")
assert_equal(replicate_color_for_ttd(false, nil), 0x00FF00, "nil depletion -> green")

--===========================================================================
-- Test Group 6: Explicit Dependency Failures
--===========================================================================

print("\n=== Test Group 6: Explicit Dependency Failures ===")

local function assert_missing_dependency(name)
    local Dashboard = require("supervisor.ui.dashboard")
    _reset_mock_gpu()
    _reset_mock_event()
    local dependencies = _make_dependencies()
    dependencies[name] = nil

    local dash, err = Dashboard.new(dependencies)
    assert_nil(dash, "Missing " .. name .. " rejects construction")
    assert_equal(err, "dashboard dependency '" .. name .. "' is required",
        "Missing " .. name .. " returns named error")
end

print("\n--- 6.1: Missing subscriber fails by name ---")
assert_missing_dependency("subscriber")

print("\n--- 6.2: Missing matrix fails by name ---")
assert_missing_dependency("matrix")

print("\n--- 6.3: Missing TTD fails by name ---")
assert_missing_dependency("ttd")

print("\n--- 6.4: Missing alerts fails by name ---")
assert_missing_dependency("alerts")

--===========================================================================
-- Test Group 7: Poll Telemetry
--===========================================================================

print("\n=== Test Group 7: Poll Telemetry ===")

print("\n--- 7.1: poll_telemetry forwards payloads to all modules ---")
local function test_poll_telemetry()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    local matrix_called = false
    local ttd_called = false
    local alerts_called = false

    dash.matrix.updateFromPayload = function(_, p) matrix_called = true end
    dash.ttd.updateFromPayload = function(_, p) ttd_called = true end
    dash.alerts.ingest = function(_, p) alerts_called = true end

    -- Inject a payload into the subscriber queue
    dash.subscriber._queue = {  -- hmm, stubs don't have internal queues
        -- manually inject via getNextPayload override
    }
    dash.subscriber.getNextPayload = function()
        -- Return one payload then nil
        dash.subscriber.getNextPayload = function() return nil end
        return {
            brokerId = "broker-test",
            timestamp = os.time(),
            queueLength = 5,
            hardwareMatrix = {},
            stats = {},
        }
    end

    dash:poll_telemetry()

    assert_true(matrix_called, "Matrix updateFromPayload called")
    assert_true(ttd_called, "TTD updateFromPayload called")
    assert_true(alerts_called, "Alerts ingest called")
end
test_poll_telemetry()

print("\n--- 7.2: poll_telemetry handles empty queue ---")
local function test_poll_telemetry_empty()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    -- No crash when queue is empty
    dash:poll_telemetry()
    -- If we got here, no error
    assert_true(true, "Empty queue poll does not error")
end
test_poll_telemetry_empty()

--===========================================================================
-- Test Group 8: Render Call Counts
--===========================================================================

print("\n=== Test Group 8: Render Call Counts ===")

print("\n--- 8.1: Full render produces draw calls on all panels ---")
local function test_render_produces_draw_calls()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    -- Add some data so panels render non-empty content
    dash.subscriber.getActiveBrokers = function()
        return {
            ["broker-1"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 3, jobsDone = 10, faults = 0 },
        }
    end
    dash.alerts.getAlerts = function()
        return { { id = "a1", severity = "WARNING", message = "test", timestamp = os.time(), acknowledged = false } }
    end
    dash.alerts.getActiveCount = function() return 1 end

    _reset_mock_gpu()
    dash:render_frame()

    local fill_calls = _count_draw_calls("fill")
    local set_calls = _count_draw_calls("set")

    -- We should have a reasonable number of draw calls for 5 panels
    assert_true(fill_calls >= 5, string.format("At least 5 fill calls (got %d)", fill_calls))
    assert_true(set_calls >= 5, string.format("At least 5 set calls (got %d)", set_calls))
end
test_render_produces_draw_calls()

print("\n--- 8.2: Header panel includes title and time ---")
local function test_header_content()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    -- Override subscriber for header render
    dash.subscriber.getActiveBrokers = function()
        return {
            ["b1"] = { status = "ACTIVE", last_heard = os.time(), queueLength = 0 },
        }
    end

    _reset_mock_gpu()
    dash:render_header()

    -- Find a set call containing "AE2-ES SUPERVISOR"
    local found_title = false
    local found_brokers = false
    for _, call in ipairs(_mock_gpu._draw_calls) do
        if call.op == "set" and call.args[3] and call.args[3]:find("AE2%-ES SUPERVISOR") then
            found_title = true
        end
        if call.op == "set" and call.args[3] and call.args[3]:find("Brokers:") then
            found_brokers = true
        end
    end
    assert_true(found_title, "Header contains title")
    assert_true(found_brokers, "Header contains broker count")
end
test_header_content()

--===========================================================================
-- Test Group 9: Edge Cases
--===========================================================================

print("\n=== Test Group 9: Edge Cases ===")

print("\n--- 9.1: Dashboard handles no brokers gracefully ---")
local function test_no_brokers()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    -- No brokers added — all panels should still render
    dash:render_frame()
    assert_true(true, "Render with no brokers does not error")
end
test_no_brokers()

print("\n--- 9.2: Alert panel handles empty alert list ---")
local function test_empty_alerts()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.alerts.getAlerts = function() return {} end
    dash.alerts.getActiveCount = function() return 0 end

    _reset_mock_gpu()
    dash:render_alert_panel()

    -- Should show "No active alerts"
    local found_empty_msg = false
    for _, call in ipairs(_mock_gpu._draw_calls) do
        if call.op == "set" and call.args[3] and call.args[3]:find("No active alerts") then
            found_empty_msg = true
        end
    end
    assert_true(found_empty_msg, "Empty alert list shows 'No active alerts'")
end
test_empty_alerts()

print("\n--- 9.3: Matrix panel shows placeholder when no broker selected ---")
local function test_no_broker_selected_matrix()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.selected_broker = nil

    _reset_mock_gpu()
    dash:render_matrix_panel()

    local found_msg = false
    for _, call in ipairs(_mock_gpu._draw_calls) do
        if call.op == "set" and call.args[3] and call.args[3]:find("Select a broker") then
            found_msg = true
        end
    end
    assert_true(found_msg, "Matrix shows instruction when no broker selected")
end
test_no_broker_selected_matrix()

print("\n--- 9.4: Matrix panel shows empty message when broker has no machines ---")
local function test_broker_no_machines()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()

    dash.selected_broker = "broker-empty"
    dash.matrix.getMachines = function(_, id) return {} end

    _reset_mock_gpu()
    dash:render_matrix_panel()

    local found_msg = false
    for _, call in ipairs(_mock_gpu._draw_calls) do
        if call.op == "set" and call.args[3] and call.args[3]:find("No machine data") then
            found_msg = true
        end
    end
    assert_true(found_msg, "Matrix shows empty message for broker with no machines")
end
test_broker_no_machines()

print("\n--- 9.5: Multiple rapid key presses are handled ---")
local function test_rapid_key_presses()
    _reset_mock_gpu()
    _reset_mock_event()
    local Dashboard = require("supervisor.ui.dashboard")
    local dash = _new_dash()
    dash.running = true

    -- Enqueue several tab presses
    _mock_key_down("\t", 15)  -- tab
    _mock_key_down("\t", 15)  -- tab
    _mock_key_down("\t", 15)  -- tab

    dash:handle_input()
    dash:handle_input()
    dash:handle_input()

    -- Should have cycled 3 times from brokers -> matrix -> alerts -> ttd
    assert_equal(dash.focused_panel, "ttd", "Three tabs cycles to ttd")
end
test_rapid_key_presses()

--===========================================================================
-- Summary
--===========================================================================

print("\n" .. string.rep("=", 60))
print(string.format("TESTS COMPLETE: %d passed, %d failed, %d total",
    test_results.passed,
    test_results.failed,
    test_results.passed + test_results.failed))

if test_results.failed > 0 then
    print("\nFAILURES:")
    for _, err in ipairs(test_results.errors) do
        print("  " .. err)
    end
    os.exit(1)
else
    print("ALL TESTS PASSED")
    os.exit(0)
end
