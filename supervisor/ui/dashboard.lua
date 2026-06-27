--===========================================================================
-- supervisor/ui/dashboard.lua
-- AE2-ES Supervisor — Dashboard UI (Task B5)
--
-- Real-time factory status view for the AE2-ES network. Renders all five
-- panels in an 80x25 terminal at 2 FPS with partial redraw for efficiency.
--
-- Panels:
--   1. Header Bar (row 1)
--   2. Broker Status Panel (rows 2-10)
--   3. Machine Matrix Panel (rows 11-18)
--   4. Alert Panel (rows 19-22)
--   5. TTD Panel (rows 23-25)
--
-- Navigation:
--   Tab       — cycle focus between panels
--   Arrow keys — navigate within focused panel
--   Enter     — select / drill down / acknowledge
--   A         — acknowledge all alerts
--   D         — dismiss resolved alerts
--   Q         — quit (return to OS)
--
-- Dependencies (soft-load via pcall):
--   B1 — supervisor.modem_subscriber (ModemSubscriber)
--   B2 — supervisor.machine_matrix  (GlobalMachineMatrix)
--   B3 — supervisor.ttd_tracker     (TTDTracker)
--   B4 — supervisor.alerts           (AlertManager)
--
-- All four modules are loaded with pcall(require) and fall back to inline
-- stubs that return empty/zero data, so the dashboard is functional even
-- when a downstream module hasn't been implemented yet.
--
-- Conventions:
--   - Lua 5.2/5.3 compatible (GTNH OpenComputers)
--   - snake_case variables, PascalCase classes, UPPER_CASE constants
--   - Metatable-based OOP (setmetatable with __index)
--   - Local functions for module-private code
--   - 1-based indexing
--===========================================================================

local Dashboard = {}
Dashboard.__index = Dashboard

--===========================================================================
-- Constants
--===========================================================================

local REFRESH_RATE = 0.5                -- seconds between frame renders (2 FPS)
local FLASH_INTERVAL = 1.0              -- seconds between alert flash toggles
local MATRIX_COLS = 4                   -- machines per row in matrix panel
local MAX_MATRIX_ROWS = 7               -- max rows in matrix panel (rows 12-18)
local ALERT_PANEL_HEIGHT = 2            -- content rows for alert panel (rows 21-22)
local BROKER_PANEL_HEIGHT = 8           -- rows for broker panel (2-9) + header

-- Panel focus identifiers
local PANEL_BROKERS  = "brokers"
local PANEL_MATRIX   = "matrix"
local PANEL_ALERTS   = "alerts"
local PANEL_TTD      = "ttd"

local PANEL_ORDER = { PANEL_BROKERS, PANEL_MATRIX, PANEL_ALERTS, PANEL_TTD }

-- Row boundaries (1-indexed terminal rows)
local ROW_HEADER       = 1
local ROW_BROKER_START = 2
local ROW_BROKER_END   = 10
local ROW_MATRIX_START = 11
local ROW_MATRIX_END   = 18
local ROW_ALERT_START  = 19
local ROW_ALERT_END    = 22
local ROW_TTD_START    = 23
local ROW_TTD_END      = 25
local TERM_COLS        = 80
local TERM_ROWS        = 25

--===========================================================================
-- Color Palette (0xRRGGBB)
--===========================================================================

local COLOR_BG          = 0x000000   -- black background
local COLOR_TEXT        = 0xFFFFFF   -- white text
local COLOR_DIM         = 0x888888   -- dim / secondary text
local COLOR_HEADER_BG   = 0x1A1A2E   -- dark navy header
local COLOR_PANEL_BG    = 0x0F0F1A   -- panel background
local COLOR_PANEL_BORDER = 0x333355  -- panel border
local COLOR_SELECTION   = 0x2A2A5A   -- selected row highlight

-- Status colors
local COLOR_ACTIVE      = 0x00FF00   -- green
local COLOR_STALE       = 0xFFFF00   -- yellow
local COLOR_OFFLINE     = 0xFF3333   -- red
local COLOR_DEADLOCKED  = 0xFF00FF   -- magenta

-- Machine status colors
local COLOR_AVL         = 0x00AA00   -- available green
local COLOR_LKD         = 0xAAAA00   -- locked yellow
local COLOR_PRC         = 0x0088FF   -- processing blue
local COLOR_FLT         = 0xFF0000   -- faulted red

-- Alert severity colors
local COLOR_CRITICAL    = 0xFF3333   -- red
local COLOR_WARNING     = 0xFFAA00   -- orange
local COLOR_INFO        = 0x3399FF   -- blue
local COLOR_RESOLVED    = 0x555555   -- grey

-- TTD colors
local COLOR_TTD_GOOD    = 0x00FF00   -- green (> 5 min)
local COLOR_TTD_WARN    = 0xFFFF00   -- yellow (1-5 min)
local COLOR_TTD_CRITICAL = 0xFF0000  -- red (< 1 min)
local COLOR_TTD_BAR_BG  = 0x222222   -- bar background

--===========================================================================
-- Module resolve helpers (soft-dependency loading)
--===========================================================================

--- Resolve a module with pcall, returning nil on failure.
-- Sets the global package.searchpath so modules under supervisor/ are findable.
local function safe_require(module_name)
    local ok, mod = pcall(require, module_name)
    if ok and mod then
        return mod
    end
    return nil
end

-- Ensure supervisor/ modules are on the Lua path
-- OC typically uses / as separator; we inject the absolute or relative root.
-- The supervisor.lua entry point will set this up; here we do best-effort.
if not package.searchpath then
    -- Lua 5.2+: add to package.path before calling require
    package.path = package.path .. ";supervisor/?.lua;src/?.lua"
end

local MatrixMod = safe_require("supervisor.machine_matrix")
local TTDMod    = safe_require("supervisor.ttd_tracker")
local AlertMod  = safe_require("supervisor.alerts")
local SubMod    = safe_require("supervisor.modem_subscriber")

--===========================================================================
-- Inline stub factories for absent modules
-- Each returns a table with the same interface as the real module.
--===========================================================================

local function make_matrix_stub()
    return {
        getMachines = function(_, broker_id)
            return {}
        end,
        getAllBrokers = function(_)
            return {}
        end,
        getMachineCount = function(_, broker_id)
            return 0
        end,
        getStats = function(_, broker_id)
            return { total = 0, available = 0, processing = 0, faulted = 0 }
        end,
        updateFromPayload = function() end,
    }
end

local function make_ttd_stub()
    return {
        getTTD = function(_)
            return {
                items  = { level = 0, max = 100, depletion_secs = 0, critical = false },
                fluids = { level = 0, max = 100, depletion_secs = 0, critical = false },
                power  = { level = 0, max = 100, depletion_secs = 0, critical = false },
            }
        end,
        updateFromPayload = function() end,
    }
end

local function make_alerts_stub()
    return {
        getAlerts = function(_)
            return {}
        end,
        acknowledge = function() end,
        acknowledgeAll = function() end,
        dismissResolved = function() end,
        getActiveCount = function(_)
            return 0
        end,
        ingest = function() end,
    }
end

local function make_subscriber_stub()
    return {
        getActiveBrokers = function(_)
            return {}
        end,
        getBrokerStatus = function()
            return nil
        end,
        getNextPayload = function()
            return nil
        end,
        getQueueSize = function()
            return 0
        end,
    }
end

--===========================================================================
-- Rendering helpers
--===========================================================================

local function color_for_status(status)
    if status == "ACTIVE"    then return COLOR_ACTIVE end
    if status == "STALE"     then return COLOR_STALE end
    if status == "OFFLINE"   then return COLOR_OFFLINE end
    if status == "DEADLOCKED" then return COLOR_DEADLOCKED end
    return COLOR_DIM
end

local function color_for_machine_status(status)
    if status == "AVAILABLE"  then return COLOR_AVL end
    if status == "LOCKED"     then return COLOR_LKD end
    if status == "PROCESSING" then return COLOR_PRC end
    if status == "FAULTED"    then return COLOR_FLT end
    return COLOR_DIM
end

local function machine_status_short(status)
    if status == "AVAILABLE"  then return "AVL" end
    if status == "LOCKED"     then return "LKD" end
    if status == "PROCESSING" then return "PRC" end
    if status == "FAULTED"    then return "FLT" end
    return "---"
end

local function color_for_alert_severity(severity)
    if severity == "CRITICAL" then return COLOR_CRITICAL end
    if severity == "WARNING"  then return COLOR_WARNING end
    if severity == "INFO"     then return COLOR_INFO end
    return COLOR_DIM
end

local function color_for_ttd(critical, depletion_secs)
    if critical or (depletion_secs and depletion_secs > 0 and depletion_secs < 60) then
        return COLOR_TTD_CRITICAL
    elseif depletion_secs and depletion_secs > 0 and depletion_secs < 300 then
        return COLOR_TTD_WARN
    end
    return COLOR_TTD_GOOD
end

--- Format seconds since epoch into HH:MM:SS
local function format_time(t)
    t = t or os.time()
    local h = math.floor(t / 3600) % 24
    local m = math.floor((t % 3600) / 60)
    local s = t % 60
    return string.format("%02d:%02d:%02d", h, m, s)
end

--- Format a relative elapsed time (seconds) into a short string
local function format_elapsed(elapsed)
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

--- Format TTD depletion seconds into a human-readable string
local function format_ttd(secs)
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

--- Draw a horizontal bar graph
-- @param gpu      GPU component proxy
-- @param x, y     Top-left position
-- @param width    Total bar width in characters
-- @param level    Current level (0-1 fraction, or raw number)
-- @param max_val  Maximum value (used if level > 1)
-- @param color    Bar fill color
local function draw_bar(gpu, x, y, width, level, max_val, color)
    local fill
    if max_val and max_val > 0 then
        fill = math.min(level / max_val, 1.0)
    else
        fill = math.min(level, 1.0)
    end
    local filled = math.floor(fill * width)

    -- Background
    gpu.setBackground(COLOR_TTD_BAR_BG)
    gpu.fill(x, y, width, 1, " ")

    -- Filled portion
    if filled > 0 then
        gpu.setBackground(color)
        gpu.fill(x, y, filled, 1, " ")
    end
end

--- Draw a panel border line (horizontal rule with corners).
local function draw_panel_hr(gpu, y)
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_PANEL_BORDER)
    local line = string.rep("\140", TERM_COLS)  -- horizontal line char
    gpu.set(1, y, line)
end

--- Fill a rectangular region with a background color
local function fill_region(gpu, x, y, w, h, color)
    gpu.setBackground(color)
    gpu.fill(x, y, w, h, " ")
end

--===========================================================================
-- Dashboard:new(subscriber, matrix, ttd, alerts)
--
-- Creates a new Dashboard instance. Accepts pre-configured dependency
-- modules (B1-B4). If any module is nil, resolves via pcall(require)
-- with inline stubs as fallbacks.
--
-- The subscriber (B1) should be created and started by the supervisor's
-- main entry point (supervisor.lua, Task B6) in a separate coroutine/thread
-- so its event loop and the dashboard render loop can coexist.
--
-- Parameters:
--   subscriber (ModemSubscriber|nil): Pre-configured modem subscriber.
--   matrix      (GlobalMachineMatrix|nil): Pre-configured machine matrix.
--   ttd         (TTDTracker|nil): Pre-configured TTD tracker.
--   alerts      (AlertManager|nil): Pre-configured alert manager.
--
-- Returns:
--   Dashboard instance, or nil + error message.
--===========================================================================
function Dashboard.new(subscriber, matrix, ttd, alerts)
    -- Resolve GPU
    local gpu
    if component and component.isAvailable and component.isAvailable("gpu") then
        gpu = component.getPrimary("gpu")
    end
    if not gpu then
        return nil, "no GPU component available — dashboard requires a screen"
    end

    local self = setmetatable({}, Dashboard)
    self.gpu = gpu
    self.running = false

    -- Resolve dependent modules (B1-B4) with stubs as fallbacks
    self.subscriber = subscriber or (SubMod and SubMod.new(123) or make_subscriber_stub())
    self.matrix      = matrix      or (MatrixMod and MatrixMod.new(self.subscriber) or make_matrix_stub())
    self.ttd         = ttd         or (TTDMod    and TTDMod.new()    or make_ttd_stub())
    self.alerts      = alerts      or (AlertMod  and AlertMod.new()  or make_alerts_stub())

    -- Navigation state
    self.focused_panel = PANEL_BROKERS
    self.focus_index = 0       -- selector within panel (0 = nothing selected)

    -- Broker panel state
    self.selected_broker = nil  -- broker ID selected for matrix detail
    self.broker_scroll = 0     -- scroll offset (0-indexed from top of view)

    -- Alert panel state
    self.alert_scroll = 0      -- scroll offset for alert list

    -- Flash state
    self.flash_timer = 0.0     -- accumulates elapsed seconds for flash toggle
    self.flash_on = false      -- current flash toggle state

    -- Cache: track last-rendered state for partial redraw optimization
    self._last_broker_count = 0
    self._last_alert_count = 0
    self._last_matrix_broker = nil
    self._last_frame_dirty = true  -- first frame always full redraw

    return self
end

--===========================================================================
-- Dashboard:start()
--
-- Begins the main render loop. Pulls telemetry, updates state, and
-- redraws at 2 FPS until the user presses Q or the loop is stopped.
--===========================================================================
function Dashboard:start()
    if self.running then
        return
    end

    self.running = true

    -- Initial full screen setup
    self:clear_screen()

    while self.running do
        local start_time = os.clock()

        -- 1. Process incoming telemetry payloads
        self:poll_telemetry()

        -- 2. Handle input (event.pull with timeout = frame rate)
        self:handle_input()

        -- 3. Render
        if self.running then
            self:render_frame()
        end

        -- Maintain 2 FPS cadence
        local elapsed = os.clock() - start_time
        if elapsed < REFRESH_RATE and self.running then
            os.sleep(REFRESH_RATE - elapsed)
        end
    end

    -- Exit: clear screen for clean return to OS
    self:clear_screen()
end

--===========================================================================
-- Dashboard:stop()
--
-- Halts the render loop. Uses computer.pushSignal to unblock any in-progress
-- event.pull(), mirroring ModemSubscriber's clean-exit pattern.
--===========================================================================
function Dashboard:stop()
    if not self.running then
        return
    end
    self.running = false
    pcall(function() computer.pushSignal("key_down") end)
end

--===========================================================================
-- Dashboard:clear_screen()
--===========================================================================
function Dashboard:clear_screen()
    local gpu = self.gpu
    gpu.setBackground(COLOR_BG)
    gpu.setForeground(COLOR_TEXT)
    gpu.fill(1, 1, TERM_COLS, TERM_ROWS, " ")
    self._last_frame_dirty = true
end

--===========================================================================
-- Dashboard:poll_telemetry()
--
-- Dequeues all pending payloads from the subscriber and forwards them to
-- the matrix, TTD, and alerts modules for state updates.
--===========================================================================
function Dashboard:poll_telemetry()
    local payload = self.subscriber:getNextPayload()
    while payload do
        -- Forward to dependent modules (these are no-ops if stubs)
        if self.matrix.updateFromPayload then
            self.matrix:updateFromPayload(payload)
        end
        if self.ttd.updateFromPayload then
            self.ttd:updateFromPayload(payload)
        end
        if self.alerts.ingest then
            self.alerts:ingest(payload)
        end

        -- Track whether we saw new data to force redraw
        self._last_frame_dirty = true

        payload = self.subscriber:getNextPayload()
    end
end

--===========================================================================
-- Dashboard:handle_input()
--
-- Pulls keyboard events with a REFRESH_RATE timeout. Processes navigation
-- and action keys.
--===========================================================================
function Dashboard:handle_input()
    local event_data = {event.pull(REFRESH_RATE, "key_down")}

    -- On nil (timeout) or non-key_down (pushSignal wakeup), just return.
    if not event_data[1] or event_data[1] ~= "key_down" then
        return
    end

    -- event.pull("key_down", _, char, code) — indices: 1=signal, 2=address, 3=char, 4=code
    local char = event_data[3]
    local code = event_data[4]

    if not char and not code then
        return
    end

    -- Navigation dispatch
    if char == "\t" then
        -- Tab: cycle focus forward
        self:cycle_focus(1)
        self._last_frame_dirty = true
        return
    end

    if code == 200 then
        -- Up arrow
        self:navigate(-1)
        self._last_frame_dirty = true
        return
    elseif code == 208 then
        -- Down arrow
        self:navigate(1)
        self._last_frame_dirty = true
        return
    elseif code == 203 then
        -- Left arrow
        self:navigate_horizontal(-1)
        self._last_frame_dirty = true
        return
    elseif code == 205 then
        -- Right arrow
        self:navigate_horizontal(1)
        self._last_frame_dirty = true
        return
    end

    if code == 28 then
        -- Enter key
        self:activate()
        self._last_frame_dirty = true
        return
    end

    -- Action keys (case-insensitive)
    local upper = char and char:upper()

    if upper == "Q" then
        self:stop()
    elseif upper == "A" then
        -- Acknowledge all alerts
        if self.alerts.acknowledgeAll then
            self.alerts:acknowledgeAll()
        end
        self._last_frame_dirty = true
    elseif upper == "D" then
        -- Dismiss resolved alerts
        if self.alerts.dismissResolved then
            self.alerts:dismissResolved()
        end
        self._last_frame_dirty = true
    end
end

--===========================================================================
-- Focus / Navigation methods
--===========================================================================

function Dashboard:cycle_focus(direction)
    local idx = nil
    for i, panel in ipairs(PANEL_ORDER) do
        if panel == self.focused_panel then
            idx = i
            break
        end
    end
    if not idx then
        self.focused_panel = PANEL_BROKERS
        self.focus_index = 0
        return
    end

    idx = idx + direction
    if idx < 1 then idx = #PANEL_ORDER end
    if idx > #PANEL_ORDER then idx = 1 end

    self.focused_panel = PANEL_ORDER[idx]
    self.focus_index = 0  -- reset selection on panel switch
end

function Dashboard:navigate(delta)
    if self.focused_panel == PANEL_BROKERS then
        local brokers = self.subscriber:getActiveBrokers()
        local broker_list = {}
        for id, _ in pairs(brokers) do
            table.insert(broker_list, id)
        end
        table.sort(broker_list)
        local count = #broker_list
        if count == 0 then
            self.focus_index = 0
            return
        end
        if self.focus_index == 0 then
            self.focus_index = (delta > 0) and 1 or count
        else
            self.focus_index = self.focus_index + delta
            if self.focus_index < 1 then self.focus_index = count end
            if self.focus_index > count then self.focus_index = 1 end
        end
        -- Adjust broker_scroll to keep selection visible (rows 5-10 = 6 visible)
            local broker_visible_max = 6
            local vis_start = self.broker_scroll + 1
            local vis_end = self.broker_scroll + broker_visible_max
            if self.focus_index < vis_start then
                self.broker_scroll = self.focus_index - 1
            elseif self.focus_index > vis_end then
                self.broker_scroll = self.focus_index - broker_visible_max
            end
            if self.broker_scroll < 0 then self.broker_scroll = 0 end

            -- Update selected broker for matrix panel
            if self.focus_index > 0 and broker_list[self.focus_index] then
                self.selected_broker = broker_list[self.focus_index]
            end

        elseif self.focused_panel == PANEL_MATRIX then
        -- Navigate machine selection within matrix
        if not self.selected_broker then return end
        local machines = self.matrix:getMachines(self.selected_broker)
        local machine_list = {}
        for addr, _ in pairs(machines) do
            table.insert(machine_list, addr)
        end
        table.sort(machine_list)
        local count = #machine_list
        if count == 0 then self.focus_index = 0; return end
        local visible = math.min(count, MAX_MATRIX_ROWS * MATRIX_COLS)
        if self.focus_index == 0 then
            self.focus_index = (delta > 0) and 1 or count
        else
            self.focus_index = self.focus_index + delta * MATRIX_COLS  -- skip by rows
            if self.focus_index < 1 then self.focus_index = 1 end
            if self.focus_index > count then self.focus_index = count end
        end

    elseif self.focused_panel == PANEL_ALERTS then
        local alerts = self.alerts:getAlerts()
        local count = #alerts
        if count == 0 then self.focus_index = 0; return end
        if self.focus_index == 0 then
            self.focus_index = (delta > 0) and 1 or count
        else
            self.focus_index = self.focus_index + delta
            if self.focus_index < 1 then self.focus_index = count end
            if self.focus_index > count then self.focus_index = 1 end
        end
        -- Adjust scroll to keep selection visible
        local vis_start = self.alert_scroll + 1
        local vis_end = self.alert_scroll + ALERT_PANEL_HEIGHT
        if self.focus_index < vis_start then
            self.alert_scroll = self.focus_index - 1
        elseif self.focus_index > vis_end then
            self.alert_scroll = self.focus_index - ALERT_PANEL_HEIGHT
        end

    elseif self.focused_panel == PANEL_TTD then
        -- Cycle through TTD categories: 1=items, 2=fluids, 3=power
        if self.focus_index == 0 then
            self.focus_index = 1
        else
            self.focus_index = self.focus_index + delta
            if self.focus_index < 1 then self.focus_index = 3 end
            if self.focus_index > 3 then self.focus_index = 1 end
        end
    end
end

function Dashboard:navigate_horizontal(delta)
    if self.focused_panel == PANEL_MATRIX then
        -- Move left/right within the matrix grid
        if not self.selected_broker then return end
        local machines = self.matrix:getMachines(self.selected_broker)
        local machine_list = {}
        for addr, _ in pairs(machines) do
            table.insert(machine_list, addr)
        end
        table.sort(machine_list)
        local count = #machine_list
        if count == 0 then return end
        if self.focus_index == 0 then
            self.focus_index = 1
        else
            self.focus_index = self.focus_index + delta
            if self.focus_index < 1 then self.focus_index = count end
            if self.focus_index > count then self.focus_index = count end
        end
    end
end

function Dashboard:activate()
    if self.focused_panel == PANEL_BROKERS then
        -- Enter on broker: lock selection for matrix detail
        if self.focus_index > 0 then
            local brokers = self.subscriber:getActiveBrokers()
            local broker_list = {}
            for id, _ in pairs(brokers) do
                table.insert(broker_list, id)
            end
            table.sort(broker_list)
            if broker_list[self.focus_index] then
                self.selected_broker = broker_list[self.focus_index]
            end
        end

    elseif self.focused_panel == PANEL_ALERTS then
        -- Enter on alert: acknowledge selected alert
        local alerts = self.alerts:getAlerts()
        if self.focus_index > 0 and alerts[self.focus_index] then
            local alert_id = alerts[self.focus_index].id
            if self.alerts.acknowledge then
                self.alerts:acknowledge(alert_id)
            end
        end

    elseif self.focused_panel == PANEL_TTD then
        -- Enter on TTD: cycle sub-focus (no action beyond display)
    end
end

--===========================================================================
-- Dashboard:render_frame()
--
-- Full-frame render with partial redraw optimization. Updates the flash
-- timer and delegates to per-panel renderers.
--===========================================================================
function Dashboard:render_frame()
    local gpu = self.gpu

    -- Update flash timer
    self.flash_timer = self.flash_timer + REFRESH_RATE
    if self.flash_timer >= FLASH_INTERVAL then
        self.flash_timer = self.flash_timer - FLASH_INTERVAL
        self.flash_on = not self.flash_on
        self._last_frame_dirty = true
    end

    -- Render all panels (each method checks dirty flag internally for
    -- partial updates, but for B5's initial implementation we do full
    -- redraw — OC GPU operations are fast enough at 2 FPS for 80x25).
    self:render_header()
    self:render_broker_panel()
    self:render_matrix_panel()
    self:render_alert_panel()
    self:render_ttd_panel()

    -- After first frame, subsequent frames only mark dirty on state change
    self._last_frame_dirty = false
end

--===========================================================================
-- Panel 1: Header Bar (row 1)
--===========================================================================
function Dashboard:render_header()
    local gpu = self.gpu
    local y = ROW_HEADER

    -- Background bar
    fill_region(gpu, 1, y, TERM_COLS, 1, COLOR_HEADER_BG)

    -- Title (left-aligned)
    gpu.setBackground(COLOR_HEADER_BG)
    gpu.setForeground(COLOR_TEXT)
    gpu.set(1, y, " AE2-ES SUPERVISOR")

    -- Center: active broker count
    local brokers = self.subscriber:getActiveBrokers()
    local total = 0
    local active = 0
    for _, info in pairs(brokers) do
        total = total + 1
        if info.status == "ACTIVE" then
            active = active + 1
        end
    end
    local count_str
    if total > 0 then
        count_str = string.format("Brokers: %d/%d", active, total)
    else
        count_str = "Brokers: 0/0"
    end
    local center_x = math.floor((TERM_COLS - #count_str) / 2) + 1
    gpu.setBackground(COLOR_HEADER_BG)
    gpu.setForeground(COLOR_DIM)
    gpu.set(center_x, y, count_str)

    -- Time (right-aligned)
    local time_str = format_time(os.time())
    gpu.setBackground(COLOR_HEADER_BG)
    gpu.setForeground(COLOR_DIM)
    gpu.set(TERM_COLS - #time_str, y, time_str)
end

--===========================================================================
-- Panel 2: Broker Status Panel (rows 2-10)
--===========================================================================
function Dashboard:render_broker_panel()
    local gpu = self.gpu

    -- Panel border top
    draw_panel_hr(gpu, ROW_BROKER_START)

    -- Column header at row 3
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_DIM)
    local header = string.format(" %-20s %-8s %-7s %-9s %-6s %-10s",
        "BROKER ID", "STATUS", "QUEUE", "JOBS DONE", "FAULTS", "LAST SEEN")
    gpu.set(1, 3, header)

    -- Panel border below header
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_PANEL_BORDER)
    gpu.set(1, 4, string.rep("\140", TERM_COLS))

    -- Broker rows (rows 5-10 = 6 visible rows)
    local brokers = self.subscriber:getActiveBrokers()
    local broker_list = {}
    for id, info in pairs(brokers) do
        table.insert(broker_list, { id = id, info = info })
    end
    table.sort(broker_list, function(a, b) return a.id < b.id end)

    local visible_start = self.broker_scroll
    local visible_max = 6  -- rows 5-10
    local focus_row = nil

    for i = 1, visible_max do
        local data_idx = visible_start + i
        local row_y = 4 + i  -- rows 5-10

        if data_idx <= #broker_list then
            local entry = broker_list[data_idx]
            local id = entry.id
            local info = entry.info
            local status = info.status or "OFFLINE"
            local status_color = color_for_status(status)

            -- Highlight selection
            local is_selected = (self.focused_panel == PANEL_BROKERS and self.focus_index == data_idx)
            local row_bg = is_selected and COLOR_SELECTION or COLOR_PANEL_BG

            fill_region(gpu, 1, row_y, TERM_COLS, 1, row_bg)

            -- Broker ID
            gpu.setBackground(row_bg)
            gpu.setForeground(COLOR_TEXT)
            gpu.set(1, row_y, " " .. id:sub(1, 19))

            -- Status with color
            gpu.setForeground(status_color)
            gpu.set(21, row_y, string.format("%-8s", status))

            -- Queue length (from broker status; use 0 if unknown)
            gpu.setForeground(COLOR_TEXT)
            local qlen = info.queueLength or 0
            gpu.set(29, row_y, string.format("%-7d", qlen % 100000))

            -- Jobs done
            local jobs = info.jobsDone or 0
            gpu.set(36, row_y, string.format("%-9d", jobs % 1000000000))

            -- Faults
            local faults = info.faults or 0
            gpu.setForeground(faults > 0 and COLOR_FLT or COLOR_TEXT)
            gpu.set(45, row_y, string.format("%-6d", faults % 10000))

            -- Last seen
            local elapsed = os.time() - (info.last_heard or 0)
            gpu.setForeground(COLOR_DIM)
            gpu.set(51, row_y, format_elapsed(elapsed))

            if is_selected then
                -- selection highlight is already drawn via row_bg
                focus_row = row_y
            end
        else
            -- Empty row
            fill_region(gpu, 1, row_y, TERM_COLS, 1, COLOR_PANEL_BG)
            gpu.setBackground(COLOR_PANEL_BG)
            gpu.setForeground(COLOR_DIM)
            gpu.set(1, row_y, " -- no broker --")
        end
    end

    -- Panel border bottom
    draw_panel_hr(gpu, ROW_BROKER_END + 1)
end

--===========================================================================
-- Panel 3: Machine Matrix Panel (rows 11-18)
--===========================================================================
function Dashboard:render_matrix_panel()
    local gpu = self.gpu

    -- Panel border top
    draw_panel_hr(gpu, ROW_MATRIX_START)

    -- Panel title
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_DIM)
    local title
    if self.selected_broker then
        title = string.format(" MACHINE MATRIX [%s]", self.selected_broker:sub(1, 20))
    else
        title = " MACHINE MATRIX [no broker selected]"
    end
    gpu.set(1, ROW_MATRIX_START + 1, title:sub(1, TERM_COLS - 1))

    -- Divider
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_PANEL_BORDER)
    gpu.set(1, ROW_MATRIX_START + 2, string.rep("\140", TERM_COLS))

    -- Machine grid (rows 13-18 = 6 rows)
    if not self.selected_broker then
        for row = 1, 6 do
            fill_region(gpu, 1, ROW_MATRIX_START + 2 + row, TERM_COLS, 1, COLOR_PANEL_BG)
            gpu.setBackground(COLOR_PANEL_BG)
            gpu.setForeground(COLOR_DIM)
            gpu.set(1, ROW_MATRIX_START + 2 + row, " Select a broker to view machine status")
        end
        return
    end

    local machines = self.matrix:getMachines(self.selected_broker)
    -- machines format: { [addr] = { status, progress, job, label }, ... }
    local machine_list = {}
    for addr, data in pairs(machines) do
        local entry = {}
        for k, v in pairs(data) do
            entry[k] = v
        end
        entry._addr = addr
        table.insert(machine_list, entry)
    end
    table.sort(machine_list, function(a, b) return (a._addr or "") < (b._addr or "") end)

    if #machine_list == 0 then
        fill_region(gpu, 1, ROW_MATRIX_START + 3, TERM_COLS, 1, COLOR_PANEL_BG)
        gpu.setBackground(COLOR_PANEL_BG)
        gpu.setForeground(COLOR_DIM)
        gpu.set(1, ROW_MATRIX_START + 3, " No machine data received from this broker")
        return
    end

    -- Render grid: MATRIX_COLS columns, up to 5 rows (rows 14-18)
    local col_width = math.floor(TERM_COLS / MATRIX_COLS)

    for idx, machine in ipairs(machine_list) do
        local col = (idx - 1) % MATRIX_COLS
        local row = math.floor((idx - 1) / MATRIX_COLS)
        if row < 5 then  -- 5 visible data rows (14-18)
            local x = 1 + col * col_width
            local y = ROW_MATRIX_START + 3 + row
            local is_selected = (self.focused_panel == PANEL_MATRIX and self.focus_index == idx)

            local status = machine.status or "AVAILABLE"
            local status_color = color_for_machine_status(status)
            local label = machine.label or (machine._addr and machine._addr:sub(1, 8))
            local progress = machine.progress or 0

            -- Status square (3 chars wide)
            local short = machine_status_short(status)
            local cell_bg = is_selected and COLOR_SELECTION or COLOR_PANEL_BG

            gpu.setBackground(cell_bg)
            gpu.setForeground(status_color)
            gpu.set(x, y, short)

            -- Label
            gpu.setBackground(cell_bg)
            gpu.setForeground(COLOR_TEXT)
            local label_text = label and label:sub(1, 8) or "---"
            gpu.set(x + 4, y, label_text)

            -- Progress bar for PROCESSING machines
            if status == "PROCESSING" then
                local bar_x = x + 4
                local bar_y = y  -- we put it after the label on same row, or next row
                -- Actually, put it on the same row after label if space allows
                local bar_w = col_width - 13
                if bar_w > 0 then
                    draw_bar(gpu, x + 13, y, bar_w, progress, 1.0, COLOR_PRC)
                end
            end
        end
    end

    -- Clear unused rows (max data rows = 5, indices 0-4)
    for r = math.ceil(#machine_list / MATRIX_COLS), 4 do
        for c = 0, MATRIX_COLS - 1 do
            fill_region(gpu, 1 + c * col_width, ROW_MATRIX_START + 3 + r, col_width, 1, COLOR_PANEL_BG)
        end
    end
end

--===========================================================================
-- Panel 4: Alert Panel (rows 19-22)
--===========================================================================
function Dashboard:render_alert_panel()
    local gpu = self.gpu

    -- Panel border top
    draw_panel_hr(gpu, ROW_ALERT_START)

    -- Title
    local alert_count = self.alerts:getActiveCount()
    local title = string.format(" ALERTS [%d active]", alert_count or 0)
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_DIM)
    gpu.set(1, ROW_ALERT_START + 1, title)

    -- Keybind hints
    gpu.setForeground(COLOR_DIM)
    gpu.set(TERM_COLS - 40, ROW_ALERT_START + 1, "[Enter]Ack  [D]Dismiss  [A]Ack All")

    -- Alert rows (rows 20-22 = 3 visible)
    local alerts = self.alerts:getAlerts()
    local visible_start = self.alert_scroll
    local visible_count = ALERT_PANEL_HEIGHT  -- 4 rows

    for i = 1, ALERT_PANEL_HEIGHT do
        local data_idx = visible_start + i
        local row_y = ROW_ALERT_START + 1 + i

        if data_idx <= #alerts then
            local alert = alerts[data_idx]
            local severity = alert.severity or "INFO"
            local sev_color = color_for_alert_severity(severity)
            local acknowledged = alert.acknowledged
            local is_selected = (self.focused_panel == PANEL_ALERTS and self.focus_index == data_idx)
            local is_critical = (severity == "CRITICAL")

            -- Flash: toggle foreground for unacknowledged CRITICAL
            local fg_color = sev_color
            if is_critical and not acknowledged and self.flash_on then
                fg_color = COLOR_BG  -- "off" = same as background (invisible)
                -- Better: toggle to dimmer color
                fg_color = COLOR_PANEL_BG
            end
            if acknowledged then
                fg_color = COLOR_RESOLVED
            end

            local row_bg = is_selected and COLOR_SELECTION or COLOR_PANEL_BG
            fill_region(gpu, 1, row_y, TERM_COLS, 1, row_bg)

            -- Severity tag
            gpu.setBackground(row_bg)
            gpu.setForeground(fg_color)
            gpu.set(1, row_y, " " .. severity:sub(1, 8))

            -- Acknowledged marker
            if acknowledged then
                gpu.setForeground(COLOR_RESOLVED)
                gpu.set(11, row_y, "[OK]")
            else
                gpu.setForeground(fg_color)
                gpu.set(11, row_y, "[!] ")
            end

            -- Message
            gpu.setForeground(COLOR_TEXT)
            local msg = alert.message or "(no message)"
            gpu.set(16, row_y, msg:sub(1, TERM_COLS - 30))

            -- Timestamp
            gpu.setForeground(COLOR_DIM)
            local ts = alert.timestamp and format_elapsed(os.time() - alert.timestamp) or "--"
            gpu.set(TERM_COLS - 15, row_y, ts)

        else
            fill_region(gpu, 1, row_y, TERM_COLS, 1, COLOR_PANEL_BG)
            gpu.setBackground(COLOR_PANEL_BG)
            gpu.setForeground(COLOR_DIM)
            if i == 1 and #alerts == 0 then
                gpu.set(1, row_y, " No active alerts")
            end
        end
    end

    -- Panel border bottom
    draw_panel_hr(gpu, ROW_ALERT_END + 1)
end

--===========================================================================
-- Panel 5: TTD Panel (rows 23-25)
--===========================================================================
function Dashboard:render_ttd_panel()
    local gpu = self.gpu

    local ttd = self.ttd:getTTD()
    local bar_width = 55  -- width of each bar
    local bar_start_x = 10

    for i, category in ipairs({"items", "fluids", "power"}) do
        local data = ttd[category]
        local y = ROW_TTD_START - 1 + i  -- rows 23, 24, 25
        local is_focused = (self.focused_panel == PANEL_TTD and self.focus_index == i)

        -- Label
        local row_bg = is_focused and COLOR_SELECTION or COLOR_BG
        fill_region(gpu, 1, y, 9, 1, row_bg)

        gpu.setBackground(row_bg)
        gpu.setForeground(COLOR_TEXT)
        local label = category:sub(1, 1):upper() .. category:sub(2)
        gpu.set(1, y, string.format(" %-8s", label))

        -- TTD depletion time
        local deplete = data.depletion_secs or 0
        local ttd_color = color_for_ttd(data.critical, deplete)
        local ttd_str = format_ttd(deplete)
        gpu.setBackground(COLOR_BG)
        gpu.setForeground(ttd_color)
        gpu.set(bar_start_x + bar_width + 2, y, ttd_str)

        -- Bar graph
        draw_bar(gpu, bar_start_x, y, bar_width,
            data.level or 0, data.max or 100, ttd_color)

        -- Level label (overlay on bar)
        gpu.setBackground(COLOR_TTD_BAR_BG)
        gpu.setForeground(ttd_color)
        local pct = data.max and data.max > 0 and math.floor((data.level / data.max) * 100) or 0
        local level_str = string.format(" %d%% ", pct)
        gpu.set(bar_start_x + math.floor(bar_width / 2) - 2, y, level_str)
    end
end

return Dashboard
