-- dashboard/helpers.lua -- color/formatter/draw helpers
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
-- Dependencies are injected explicitly by the composition root:
--   subscriber — canonical src.supervisor instance
--   matrix     — GlobalMachineMatrix implementation
--   ttd        — TTDTracker implementation
--   alerts     — AlertManager implementation
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
local PANEL_LOG      = "log"

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

local REQUIRED_METHODS = {
    subscriber = { "getActiveBrokers", "getBrokerStatus", "getNextPayload", "getQueueSize" },
    matrix = { "getMachines", "getAllBrokers", "getMachineCount", "getStats", "updateFromPayload" },
    ttd = { "getTTD", "updateFromPayload" },
    alerts = {
        "getAlerts", "acknowledge", "acknowledgeAll", "dismissResolved",
        "getActiveCount", "ingest",
    },
}

local function validate_dependency(name, dependency)
    if type(dependency) ~= "table" then
        return "dashboard dependency '" .. name .. "' is required"
    end
    for _, method in ipairs(REQUIRED_METHODS[name]) do
        if type(dependency[method]) ~= "function" then
            return "dashboard dependency '" .. name .. "." .. method .. "' must be a function"
        end
    end
    return nil
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
-- Dashboard:new(dependencies)
--
-- Creates a new Dashboard instance from explicit, pre-configured dependencies.
-- Missing or incomplete capabilities fail construction instead of rendering
-- empty production data.
--
-- Parameters:
--   dependencies.subscriber: canonical src.supervisor instance.
--   dependencies.matrix: GlobalMachineMatrix instance.
--   dependencies.ttd: TTDTracker instance.
--   dependencies.alerts: AlertManager instance.
--
-- Returns:
--   Dashboard instance, or nil + error message.
--===========================================================================

return Dashboard
