--=============================================================================
-- supervisor/config_ui.lua
-- AE2-ES Supervisor — Interactive Configuration UI (Task B7)
--
-- Provides both a first-run setup wizard and a runtime configuration menu
-- for the AE2-ES Supervisor. The configuration is persisted to a serialized
-- Lua table at /home/ae2es_supervisor.cfg.
--
-- Architecture:
--   config_ui runs its own event loop using event.pull() for keyboard input.
--   After use, control returns to the caller (supervisor.lua or standalone).
--
-- Config file format: serialized Lua table (via OC serialization API).
-- Keys match the CONFIG table in supervisor.lua:
--   supervisorPort, maxQueueSize, queueTrimTarget, maxLogEntries,
--   healthCheckInterval, ttdThresholds, dashboardLayout, brokerRegistry
--
-- Dependencies:
--   lib/ui_common.lua — Shared UI widget library
--   component, event, serialization — OpenComputers APIs
--   filesystem — OC file I/O
--
-- Conventions:
--   - Lua 5.2/5.3 compatible (GTNH OpenComputers)
--   - Cooperative multitasking: all loops yield via event.pull()
--   - snake_case functions, PascalCase classes, UPPER_CASE constants
--   - Metatable-based OOP for the ConfigUI class
--=============================================================================

-- Soft-load OC dependencies (testable in standalone Lua)
local component
local ok_c, _ = pcall(function() component = require("component") end)
if not ok_c or not component then
    component = _G.component or { list = function() return function() return nil end end, isAvailable = function() return false end }
end

local event
local ok_e, _ = pcall(function() event = require("event") end)
if not ok_e or not event then
    event = _G.event or {}
end

local serialization
local ok_s, _ = pcall(function() serialization = require("serialization") end)
if not ok_s or not serialization then
    serialization = _G.serialization or {}
end
local UI = require("lib.ui_common")

--=============================================================================
-- Constants
--=============================================================================

local CONFIG_PATH = "/home/ae2es_supervisor.cfg"

-- Default configuration (mirrors supervisor.lua CONFIG defaults)
local DEFAULT_CONFIG = {
    supervisorPort     = 123,
    supervisorId       = "supervisor",
    useProgramFramework = false,
    controlPort        = 124,
    enableRemoteControl = false,
    enableRemoteThrottle = false,
    enableRemoteRestart = false,
    controlAuthSecret = "",
    maxQueueSize       = 1000,
    queueTrimTarget    = 500,
    maxLogEntries      = 200,
    healthCheckInterval = 5.0,

    -- TTD thresholds: { resource_type = { warning=secs, critical=secs } }
    ttdThresholds = {
        items  = { warning = 600,  critical = 120 },
        fluids = { warning = 600,  critical = 120 },
        power  = { warning = 300,  critical = 60  },
    },

    -- Dashboard layout preferences
    dashboardLayout = {
        mode         = "compact",   -- "compact" or "full"
        refreshRate  = 0.5,         -- seconds (2 FPS default)
        showAlerts   = true,        -- show alert panel
        showTTD      = true,        -- show TTD panel
        showBrokers  = true,        -- show broker panel
        showMatrix   = true,        -- show machine matrix
    },

    -- Broker registry: array of broker IDs expected in the network
    brokerRegistry = {},
}

-- Tab constants
local TAB_MODEM     = 1
local TAB_TTD       = 2
local TAB_DASHBOARD = 3
local TAB_BROKERS   = 4

local TAB_LABELS = { " Modem ", " TTD ", " Dashboard ", " Brokers " }

--=============================================================================
-- ConfigUI Class
--=============================================================================

local ConfigUI = {}
ConfigUI.__index = ConfigUI

--- Create a new ConfigUI instance.
--- @param config table|nil  Existing config to edit (loaded from file)
--- @return ConfigUI
function ConfigUI.new(config)
    local self = setmetatable({}, ConfigUI)

    -- Merge with defaults
    self._config = UI.deep_copy(DEFAULT_CONFIG)
    if config then
        for k, v in pairs(config) do
            self._config[k] = v
        end
    end

    -- Resolve GPU
    self._gpu = nil
    if component.isAvailable("gpu") then
        self._gpu = component.getPrimary("gpu")
    end

    -- Terminal dimensions
    self._term_cols = 80
    self._term_rows = 25
    if self._gpu then
        local w, h = self._gpu.getResolution()
        self._term_cols = w or 80
        self._term_rows = h or 25
    end

    -- UI state
    self._running = false
    self._active_tab = TAB_MODEM
    self._modified = false          -- track if changes were made
    self._broker_scroll = 0
    self._broker_selection = 0

    return self
end


--=============================================================================
-- File I/O
--=============================================================================

--- Load configuration from the config file.
---@param path string|nil Optional config path
--- @return table|nil config, string|nil error
function ConfigUI.load_config(path)
    path = path or CONFIG_PATH
    local fs_ok, fs = pcall(require, "filesystem")
    if not fs_ok or not fs then
        -- Standalone Lua: try io.open directly
        local file, err = io.open(path, "r")
        if not file then
            return nil, "cannot open config file: " .. tostring(err)
        end
        local content = file:read("*a")
        file:close()
        if not content or content == "" then
            return nil, "empty config file"
        end
        local ok, data = pcall(serialization.unserialize, content)
        if not ok or type(data) ~= "table" then
            return nil, "corrupt config file"
        end
        return data, nil
    end

    if not fs.exists(path) then
        return nil, "config file not found"
    end

    local file, err = io.open(path, "r")
    if not file then
        return nil, "cannot open config file: " .. tostring(err)
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return nil, "empty config file"
    end

    local ok, data = pcall(serialization.unserialize, content)
    if not ok or type(data) ~= "table" then
        return nil, "corrupt config file"
    end

    return data, nil
end

--- Save configuration to the config file.
--- @param config table
--- @return boolean success, string|nil error
function ConfigUI.save_config(config)
    local serialized = serialization.serialize(config)
    if not serialized then
        return false, "serialization failed"
    end

    local file, err = io.open(CONFIG_PATH, "w")
    if not file then
        return false, "cannot write config file: " .. tostring(err)
    end

    file:write(serialized)
    file:close()
    return true, nil
end

--- Check if the config file exists on disk.
--- @return boolean
function ConfigUI.config_exists()
    local fs_ok, fs = pcall(require, "filesystem")
    if fs_ok and fs then
        return fs.exists(CONFIG_PATH)
    end
    -- Fallback: try io.open
    local file = io.open(CONFIG_PATH, "r")
    if file then
        file:close()
        return true
    end
    return false
end

--=============================================================================
-- Getters for Supervisor integration
--=============================================================================

--- Get the current configuration table (compatible with Supervisor.new).
--- @return table
function ConfigUI:get_config()
    return UI.deep_copy(self._config)
end

--- Get the config file path.
--- @return string
function ConfigUI.get_config_path()
    return CONFIG_PATH
end

--=============================================================================
-- First-Run Setup Wizard
--=============================================================================

--- Run the first-run setup wizard. Guides the user through detecting
--- hardware and configuring all essential parameters.
--- @return boolean completed (false if user cancelled)
function ConfigUI:run_wizard()
    local gpu = self._gpu
    local cols = self._term_cols
    local rows = self._term_rows

    UI.clear_screen(gpu, cols, rows)
    UI.draw_centered(gpu, 3, "AE2-ES Supervisor — Setup Wizard", cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)
    UI.draw_centered(gpu, 5, "This wizard will help you configure your Supervisor.", cols, UI.COLOR.TEXT, UI.COLOR.BG)
    UI.draw_centered(gpu, 6, "Press Enter to continue, or Esc to cancel.", cols, UI.COLOR.DIM, UI.COLOR.BG)

    -- Wait for key
    local key = {event.pull()}
    if key[1] ~= "key_down" or key[4] == UI.KEY.ESCAPE then
        return false
    end

    -- Step 1: Detect modem
    UI.clear_screen(gpu, cols, rows)
    UI.draw_centered(gpu, 3, "Step 1: Modem Detection", cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)

    local modem_found = false
    local modem_address = nil
    for addr, ctype in component.list() do
        if ctype == "modem" then
            modem_found = true
            modem_address = addr
            break
        end
    end

    if modem_found then
        UI.draw_centered(gpu, 6, "Modem detected!", cols, UI.COLOR.SUCCESS, UI.COLOR.BG)
        UI.draw_centered(gpu, 7, "Address: " .. (modem_address or "unknown"), cols, UI.COLOR.DIM, UI.COLOR.BG)
    else
        UI.draw_centered(gpu, 6, "No modem detected.", cols, UI.COLOR.WARNING, UI.COLOR.BG)
        UI.draw_centered(gpu, 7, "The Supervisor can still run, but cannot receive telemetry.", cols, UI.COLOR.DIM, UI.COLOR.BG)
        UI.draw_centered(gpu, 8, "Install a modem and restart the wizard.", cols, UI.COLOR.DIM, UI.COLOR.BG)
    end

    UI.draw_centered(gpu, rows - 2, "Press Enter to continue", cols, UI.COLOR.DIM, UI.COLOR.BG)
    key = {event.pull()}
    if key[1] ~= "key_down" or key[4] == UI.KEY.ESCAPE then return false end

    -- Step 2: Configure modem port
    local port_str = UI.input_dialog(gpu,
        "Enter Supervisor modem port:",
        tostring(self._config.supervisorPort),
        cols)
    if port_str then
        local port = tonumber(port_str)
        if port and port >= 1 and port <= 65535 then
            self._config.supervisorPort = port
            self._modified = true
        else
            UI.message_dialog(gpu, "Invalid Port",
                {"Port must be between 1 and 65535.",
                 "Keeping current value: " .. self._config.supervisorPort},
                cols)
        end
    end

    -- Step 3: Screen resolution preferences
    local res_menu = {
        { label = "80x25 (Standard OC screen)" },
        { label = "80x50 (Advanced OC screen)" },
        { label = "160x50 (High-res screen)" },
    }
    local res_selection = UI.show_menu(gpu, "Step 3: Select Screen Layout", res_menu,
        nil, nil, 50, cols)
    if res_selection then
        if res_selection == res_menu[1] then
            self._config.dashboardLayout.mode = "compact"
        elseif res_selection == res_menu[2] then
            self._config.dashboardLayout.mode = "full"
        else
            self._config.dashboardLayout.mode = "full"
        end
        self._modified = true
    end

    -- Step 4: TTD thresholds
    UI.clear_screen(gpu, cols, rows)
    UI.draw_centered(gpu, 3, "Step 4: TTD (Time-To-Depletion) Thresholds", cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)
    UI.draw_centered(gpu, 5, "Define warning and critical thresholds for each resource.", cols, UI.COLOR.TEXT, UI.COLOR.BG)
    UI.draw_centered(gpu, 6, "Warning threshold: seconds before yellow alert.", cols, UI.COLOR.DIM, UI.COLOR.BG)
    UI.draw_centered(gpu, 7, "Critical threshold: seconds before red alert.", cols, UI.COLOR.DIM, UI.COLOR.BG)
    UI.draw_centered(gpu, rows - 2, "Press Enter to continue", cols, UI.COLOR.DIM, UI.COLOR.BG)

    key = {event.pull()}
    if key[1] ~= "key_down" or key[4] == UI.KEY.ESCAPE then return false end

    local ttd_types = { "items", "fluids", "power" }
    for _, rtype in ipairs(ttd_types) do
        local thresholds = self._config.ttdThresholds[rtype]
        local w_str = UI.input_dialog(gpu,
            string.format("%s Warning threshold (seconds):", rtype:upper()),
            tostring(thresholds.warning), cols)
        if w_str then
            local w = tonumber(w_str)
            if w and w > 0 then thresholds.warning = w end
        end

        local c_str = UI.input_dialog(gpu,
            string.format("%s Critical threshold (seconds):", rtype:upper()),
            tostring(thresholds.critical), cols)
        if c_str then
            local c = tonumber(c_str)
            if c and c > 0 then thresholds.critical = c end
        end

        self._modified = true
    end

    -- Step 5: Pre-register broker IDs
    UI.clear_screen(gpu, cols, rows)
    UI.draw_centered(gpu, 3, "Step 5: Broker Registration", cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)
    UI.draw_centered(gpu, 5, "Optionally register known broker IDs for health monitoring.", cols, UI.COLOR.TEXT, UI.COLOR.BG)
    UI.draw_centered(gpu, 6, "You can add or remove brokers later from the runtime menu.", cols, UI.COLOR.DIM, UI.COLOR.BG)

    -- Ask if user wants to add brokers now
    local add_brokers = UI.confirm_dialog(gpu, "Register broker IDs now?", cols)
    if add_brokers then
        local add_more = true
        while add_more do
            local broker_id = UI.input_dialog(gpu,
                "Enter broker ID (or leave empty to finish):",
                "", cols)
            if broker_id and #broker_id > 0 then
                table.insert(self._config.brokerRegistry, broker_id)
                self._modified = true
                UI.message_dialog(gpu, "Broker Added",
                    string.format("Registered broker: %s", broker_id), cols)
            else
                add_more = false
            end
        end
    end

    -- Step 6: Save
    self:save_current()
    self._modified = false

    UI.message_dialog(gpu, "Setup Complete",
        {"Configuration saved to " .. CONFIG_PATH,
         "You can now start the Supervisor.",
         "Press any key to continue."}, cols)

    return true
end

--=============================================================================
-- Runtime Configuration Menu (Tabbed Interface)
--=============================================================================

--- Run the main runtime configuration interface.
--- Blocks until user exits. Shows tabbed: Modem | TTD | Dashboard | Brokers.
--- @return boolean modified (true if config was saved)
function ConfigUI:run()
    self._running = true
    self._modified = false

    while self._running do
        self:_render_all_tabs()

        -- Wait for keyboard input
        local key = {event.pull()}
        if key[1] == "key_down" then
            self:_handle_input(key[3], key[4])
        elseif key[1] == "interrupted" then
            self._running = false
        end
    end

    -- If modified, ask to save
    if self._modified then
        if self._gpu then
            local ok = UI.confirm_dialog(self._gpu, "Save changes?", self._term_cols)
            if ok then
                self:save_current()
            end
        else
            self:save_current()
        end
    end

    return self._modified
end

--- Save the current configuration to disk.
--- @return boolean success
function ConfigUI:save_current()
    local ok, err = ConfigUI.save_config(self._config)
    if ok then
        self._modified = false
        return true
    end
    return false
end

--=============================================================================
-- Tab Rendering
--=============================================================================

--- Render all elements of the current interface.
function ConfigUI:_render_all_tabs()
    local gpu = self._gpu
    local cols = self._term_cols
    local rows = self._term_rows

    if not gpu then return end

    UI.clear_screen(gpu, cols, rows)

    -- Tab bar
    UI.draw_tabs(gpu, TAB_LABELS, self._active_tab, 1, 1, cols)

    -- Title row
    local modified_marker = self._modified and " *" or ""
    UI.draw_centered(gpu, 2, "Supervisor Configuration" .. modified_marker, cols, UI.COLOR.HIGHLIGHT, UI.COLOR.BG)

    -- Separator
    UI.draw_hr(gpu, 3, cols)

    -- Render the active tab content
    if self._active_tab == TAB_MODEM then
        self:_render_modem_tab()
    elseif self._active_tab == TAB_TTD then
        self:_render_ttd_tab()
    elseif self._active_tab == TAB_DASHBOARD then
        self:_render_dashboard_tab()
    elseif self._active_tab == TAB_BROKERS then
        self:_render_brokers_tab()
    end

    -- Bottom help bar
    self:_render_help_bar()
end

--- Render the bottom help bar with available keybindings.
function ConfigUI:_render_help_bar()
    local gpu = self._gpu
    local cols = self._term_cols
    local rows = self._term_rows

    local help = "Tab: Next tab   Shift+Tab: Prev tab   Enter: Edit   S: Save   R: Reset   Q: Quit"
    gpu.setBackground(UI.COLOR.HEADER_BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.fill(1, rows, cols, 1, " ")
    gpu.set(1, rows, help:sub(1, cols - 1))
end

--=============================================================================
-- Modem Tab
--=============================================================================

function ConfigUI:_render_modem_tab()
    local gpu = self._gpu
    local cols = self._term_cols
    local y = 5

    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.LABEL)
    gpu.set(3, y, "Modem Configuration")
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    gpu.set(3, y + 1, string.rep("\\140", 40))
    y = y + 2

    -- Supervisor port
    UI.draw_field(gpu, 5, y, "Supervisor Port:      ", tostring(self._config.supervisorPort), UI.COLOR.INFO)
    y = y + 1
    UI.draw_field(gpu, 5, y, "Max Queue Size:       ", tostring(self._config.maxQueueSize), UI.COLOR.TEXT)
    y = y + 1
    UI.draw_field(gpu, 5, y, "Queue Trim Target:    ", tostring(self._config.queueTrimTarget), UI.COLOR.TEXT)
    y = y + 1
    UI.draw_field(gpu, 5, y, "Health Check Interval: ", string.format("%.1f sec", self._config.healthCheckInterval), UI.COLOR.TEXT)
    y = y + 1
    UI.draw_field(gpu, 5, y, "Log Buffer Size:      ", tostring(self._config.maxLogEntries), UI.COLOR.TEXT)
    y = y + 2

    -- Modem connectivity test hint
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.set(5, y, "Use T to test modem connectivity")
end

--=============================================================================
-- TTD Tab
--=============================================================================

function ConfigUI:_render_ttd_tab()
    local gpu = self._gpu
    local cols = self._term_cols
    local y = 5

    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.LABEL)
    gpu.set(3, y, "TTD (Time-To-Depletion) Thresholds")
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    gpu.set(3, y + 1, string.rep("\\140", 50))
    y = y + 2

    -- TTD thresholds table
    local rtypes = { "Items", "Fluids", "Power" }
    local keys = { "items", "fluids", "power" }

    -- Column headers
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.set(5, y, string.format("%-10s %-18s %-18s %s", "Resource", "Warning (seconds)", "Critical (seconds)", "Status"))
    y = y + 1

    for i, rtype in ipairs(keys) do
        local thresholds = self._config.ttdThresholds[rtype]
        gpu.setBackground(UI.COLOR.BG)
        gpu.setForeground(UI.COLOR.TEXT)
        gpu.set(5, y, string.format("%-10s %-18d %-18d", rtypes[i], thresholds.warning, thresholds.critical))

        -- Status indicator
        gpu.setForeground(UI.COLOR.TTD_GOOD)
        gpu.set(5 + 10 + 18 + 18, y, "OK")

        y = y + 1
    end

    y = y + 1
    -- Edit hint
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.set(5, y, "Press E to edit TTD thresholds")
end

--=============================================================================
-- Dashboard Tab
--=============================================================================

function ConfigUI:_render_dashboard_tab()
    local gpu = self._gpu
    local cols = self._term_cols
    local y = 5

    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.LABEL)
    gpu.set(3, y, "Dashboard Layout")
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    gpu.set(3, y + 1, string.rep("\\140", 40))
    y = y + 2

    -- Layout mode
    UI.draw_field(gpu, 5, y, "Layout Mode:       ", self._config.dashboardLayout.mode, UI.COLOR.INFO)
    y = y + 1
    UI.draw_field(gpu, 5, y, "Refresh Rate:      ", string.format("%.1f sec", self._config.dashboardLayout.refreshRate), UI.COLOR.TEXT)
    y = y + 1

    -- Panel visibility toggles
    for _, panel in ipairs({
        { key = "showBrokers",  label = "Broker Panel" },
        { key = "showMatrix",   label = "Machine Matrix" },
        { key = "showAlerts",   label = "Alert Panel" },
        { key = "showTTD",      label = "TTD Panel" },
    }) do
        local visible = self._config.dashboardLayout[panel.key]
        local status_str = visible and "Visible  [X]" or "Hidden   [ ]"
        local status_color = visible and UI.COLOR.TTD_GOOD or UI.COLOR.DISABLED
        UI.draw_field(gpu, 5, y, panel.label .. ": ", status_str, status_color)
        y = y + 1
    end

    y = y + 1
    -- Edit hints
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.set(5, y, "Press 1-4 to toggle panel visibility, F to toggle full/compact")
end

--=============================================================================
-- Brokers Tab
--=============================================================================

function ConfigUI:_render_brokers_tab()
    local gpu = self._gpu
    local cols = self._term_cols
    local y = 5

    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.LABEL)
    gpu.set(3, y, "Broker Registry")
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    gpu.set(3, y + 1, string.rep("\\140", 40))
    y = y + 2

    -- Registered broker IDs
    local brokers = self._config.brokerRegistry
    if #brokers == 0 then
        gpu.setBackground(UI.COLOR.BG)
        gpu.setForeground(UI.COLOR.DIM)
        gpu.set(5, y, "No brokers registered. Brokers are auto-discovered on first contact.")
    else
        table.sort(brokers)
        local max_visible = 12
        local start_idx = self._broker_scroll + 1
        local end_idx = math.min(start_idx + max_visible - 1, #brokers)

        gpu.setBackground(UI.COLOR.BG)
        gpu.setForeground(UI.COLOR.DIM)
        gpu.set(5, y, string.format("%-4s %-30s %-10s", "#", "Broker ID", "Status"))

        for i = start_idx, end_idx do
            local idx = i - start_idx
            local is_selected = (i == self._broker_selection)
            local bg = is_selected and UI.COLOR.SELECTION or UI.COLOR.BG

            gpu.setBackground(bg)
            gpu.setForeground(is_selected and UI.COLOR.HIGHLIGHT or UI.COLOR.TEXT)
            gpu.set(5, y + 1 + idx, string.format("%-4d %-30s", i, UI.truncate(brokers[i], 30)))

            -- Status: gray (not yet heard from)
            UI.write_status(gpu, 5 + 4 + 30, y + 1 + idx, "pending")
        end
    end

    y = y + 14
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.set(5, y, "A: Add broker   D: Delete selected   Up/Down: Navigate")
end

--=============================================================================
-- Input Handling
--=============================================================================

--- Handle a key_down event for the runtime config UI.
--- @param char number ASCII character code (or nil)
--- @param code number Key code
function ConfigUI:_handle_input(char, code)
    local upper = char and string.char(char):upper()

    -- Tab: cycle forward
    -- Shift+Tab: handled via char code (15 for Tab, we cycle forward)
    if code == UI.KEY.TAB then
        self._active_tab = self._active_tab + 1
        if self._active_tab > #TAB_LABELS then
            self._active_tab = 1
        end
        return
    end

    -- Escape or Q: quit
    if code == UI.KEY.ESCAPE or upper == "Q" then
        self._running = false
        return
    end

    -- S: save
    if upper == "S" then
        if self:save_current() then
            if self._gpu then
                UI.message_dialog(self._gpu, "Saved",
                    "Configuration saved to " .. CONFIG_PATH,
                    self._term_cols)
            end
        else
            if self._gpu then
                UI.message_dialog(self._gpu, "Error",
                    {"Failed to save configuration.",
                     "Check filesystem permissions."},
                    self._term_cols)
            end
        end
        return
    end

    -- R: reset to defaults
    if upper == "R" then
        if self._gpu then
            local ok = UI.confirm_dialog(self._gpu,
                "Reset all settings to defaults?", self._term_cols)
            if ok then
                self._config = UI.deep_copy(DEFAULT_CONFIG)
                self._modified = true
                UI.message_dialog(self._gpu, "Reset",
                    "All settings have been reset to defaults.",
                    self._term_cols)
            end
        end
        return
    end

    -- T: test modem connectivity
    if upper == "T" and self._active_tab == TAB_MODEM then
        self:_test_modem()
        return
    end

    -- E: edit TTD thresholds
    if upper == "E" and self._active_tab == TAB_TTD then
        self:_edit_ttd_thresholds()
        return
    end

    -- F: toggle dashboard layout mode
    if upper == "F" and self._active_tab == TAB_DASHBOARD then
        if self._config.dashboardLayout.mode == "compact" then
            self._config.dashboardLayout.mode = "full"
        else
            self._config.dashboardLayout.mode = "compact"
        end
        self._modified = true
        return
    end

    -- 1-4: toggle panel visibility (Dashboard tab)
    if self._active_tab == TAB_DASHBOARD then
        local panel_keys = { "showBrokers", "showMatrix", "showAlerts", "showTTD" }
        if char and char >= 49 and char <= 52 then  -- '1' to '4'
            local idx = char - 48
            if idx >= 1 and idx <= #panel_keys then
                local key = panel_keys[idx]
                self._config.dashboardLayout[key] = not self._config.dashboardLayout[key]
                self._modified = true
            end
            return
        end
    end

    -- Broker tab operations
    if self._active_tab == TAB_BROKERS then
        -- Up/Down navigation
        if code == UI.KEY.UP then
            self._broker_selection = self._broker_selection - 1
            if self._broker_selection < 0 then
                self._broker_selection = #self._config.brokerRegistry
            end
            return
        elseif code == UI.KEY.DOWN then
            self._broker_selection = self._broker_selection + 1
            if self._broker_selection > #self._config.brokerRegistry then
                self._broker_selection = 0
            end
            return
        end

        -- A: Add broker
        if upper == "A" then
            self:_add_broker()
            return
        end

        -- D: Delete selected broker
        if upper == "D" then
            self:_delete_broker()
            return
        end
    end

    -- Port editing on Modem tab: Enter or P
    if self._active_tab == TAB_MODEM then
        if code == UI.KEY.ENTER or upper == "P" then
            self:_edit_modem_settings()
            return
        end
    end

    -- Number keys on Modem tab: quick-edit specific field
    if self._active_tab == TAB_MODEM and char and char >= 49 and char <= 53 then
        local idx = char - 48
        self:_edit_modem_field(idx)
        return
    end
end

--=============================================================================
-- Sub-editors
--=============================================================================

--- Test modem connectivity by attempting to open and close the configured port.
function ConfigUI:_test_modem()
    local gpu = self._gpu
    local cols = self._term_cols

    UI.clear_screen(gpu, cols, self._term_rows)
    UI.draw_centered(gpu, 5, "Modem Connectivity Test", cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)

    -- Check modem availability
    local modem = nil
    for addr, ctype in component.list() do
        if ctype == "modem" then
            modem = component.proxy(addr)
            break
        end
    end

    if not modem then
        UI.draw_centered(gpu, 8, "No modem component available!", cols, UI.COLOR.ERROR, UI.COLOR.BG)
        UI.draw_centered(gpu, 10, "Install a modem and restart the Supervisor.", cols, UI.COLOR.DIM, UI.COLOR.BG)
        UI.draw_centered(gpu, self._term_rows - 2, "Press any key to continue", cols, UI.COLOR.DIM, UI.COLOR.BG)
        local _ = {event.pull()}
        return
    end

    UI.draw_centered(gpu, 8, "Modem found. Testing port " .. self._config.supervisorPort .. "...", cols, UI.COLOR.SUCCESS, UI.COLOR.BG)

    -- Try to open the port
    local ok, err = pcall(modem.open, modem, self._config.supervisorPort)
    if ok then
        UI.draw_centered(gpu, 10, "Port opened successfully.", cols, UI.COLOR.SUCCESS, UI.COLOR.BG)

        -- Try to close it
        pcall(modem.close, modem, self._config.supervisorPort)
        UI.draw_centered(gpu, 11, "Port closed cleanly.", cols, UI.COLOR.SUCCESS, UI.COLOR.BG)
        UI.draw_centered(gpu, 13, "Test PASSED", cols, UI.COLOR.TTD_GOOD, UI.COLOR.BG)
    else
        UI.draw_centered(gpu, 10, "Failed to open port: " .. tostring(err), cols, UI.COLOR.ERROR, UI.COLOR.BG)
        UI.draw_centered(gpu, 12, "Test FAILED", cols, UI.COLOR.ERROR, UI.COLOR.BG)
    end

    UI.draw_centered(gpu, self._term_rows - 2, "Press any key to continue", cols, UI.COLOR.DIM, UI.COLOR.BG)
    local _ = {event.pull()}
end

--- Edit TTD thresholds for all resource types.
function ConfigUI:_edit_ttd_thresholds()
    local gpu = self._gpu
    local cols = self._term_cols

    local rtypes = { "items", "fluids", "power" }
    local labels = { "Items", "Fluids", "Power" }

    for i, rtype in ipairs(rtypes) do
        local thresholds = self._config.ttdThresholds[rtype]

        UI.clear_screen(gpu, cols, self._term_rows)
        UI.draw_centered(gpu, 3, string.format("Edit TTD Thresholds: %s", labels[i]),
            cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)

        local w_str = UI.input_dialog(gpu,
            string.format("Warning threshold for %s (seconds, current: %d):",
                labels[i], thresholds.warning),
            tostring(thresholds.warning), cols)
        if w_str then
            local w = tonumber(w_str)
            if w and w > 0 then
                thresholds.warning = w
                self._modified = true
            end
        end

        local c_str = UI.input_dialog(gpu,
            string.format("Critical threshold for %s (seconds, current: %d):",
                labels[i], thresholds.critical),
            tostring(thresholds.critical), cols)
        if c_str then
            local c = tonumber(c_str)
            if c and c > 0 then
                thresholds.critical = c
                self._modified = true
            end
        end
    end
end

--- Edit modem settings fields.
function ConfigUI:_edit_modem_settings()
    local gpu = self._gpu
    local cols = self._term_cols

    -- Supervisor port
    local port_str = UI.input_dialog(gpu,
        "Supervisor port (1-65535):",
        tostring(self._config.supervisorPort), cols)
    if port_str then
        local p = tonumber(port_str)
        if p and p >= 1 and p <= 65535 then
            self._config.supervisorPort = p
            self._modified = true
        end
    end

    -- Max queue size
    local q_str = UI.input_dialog(gpu,
        "Max queue size:",
        tostring(self._config.maxQueueSize), cols)
    if q_str then
        local q = tonumber(q_str)
        if q and q >= 10 and q <= 100000 then
            self._config.maxQueueSize = q
            self._modified = true
        end
    end

    -- Queue trim target
    local t_str = UI.input_dialog(gpu,
        "Queue trim target (must be < max queue):",
        tostring(self._config.queueTrimTarget), cols)
    if t_str then
        local t = tonumber(t_str)
        if t and t >= 1 and t < self._config.maxQueueSize then
            self._config.queueTrimTarget = t
            self._modified = true
        end
    end

    -- Health check interval
    local h_str = UI.input_dialog(gpu,
        "Health check interval (seconds, 1-300):",
        string.format("%.1f", self._config.healthCheckInterval), cols)
    if h_str then
        local h = tonumber(h_str)
        if h and h >= 0.5 and h <= 300 then
            self._config.healthCheckInterval = h
            self._modified = true
        end
    end

    -- Log buffer size
    local l_str = UI.input_dialog(gpu,
        "Log buffer size (50-5000):",
        tostring(self._config.maxLogEntries), cols)
    if l_str then
        local l = tonumber(l_str)
        if l and l >= 50 and l <= 5000 then
            self._config.maxLogEntries = l
            self._modified = true
        end
    end
end

--- Edit a specific modem field by index (1-5).
function ConfigUI:_edit_modem_field(idx)
    local fields = {
        { key = "supervisorPort",     label = "Supervisor port",     default = 123 },
        { key = "maxQueueSize",       label = "Max queue size",      default = 1000 },
        { key = "queueTrimTarget",    label = "Queue trim target",   default = 500 },
        { key = "healthCheckInterval", label = "Health check interval", default = 5.0 },
        { key = "maxLogEntries",      label = "Log buffer size",     default = 200 },
    }

    local field = fields[idx]
    if not field then return end

    local gpu = self._gpu
    local cols = self._term_cols
    local current = tostring(self._config[field.key])

    local str = UI.input_dialog(gpu, field.label .. ":", current, cols)
    if str then
        local val = tonumber(str)
        if val then
            self._config[field.key] = val
            self._modified = true
        end
    end
end

--- Add a broker ID to the registry.
function ConfigUI:_add_broker()
    local gpu = self._gpu
    local cols = self._term_cols

    local broker_id = UI.input_dialog(gpu,
        "Enter broker ID to register:", "", cols)
    if broker_id and #broker_id > 0 then
        -- Check for duplicates
        for _, existing in ipairs(self._config.brokerRegistry) do
            if existing == broker_id then
                UI.message_dialog(gpu, "Duplicate",
                    "Broker '" .. broker_id .. "' is already registered.",
                    cols)
                return
            end
        end

        table.insert(self._config.brokerRegistry, broker_id)
        self._modified = true
        UI.message_dialog(gpu, "Added",
            "Broker '" .. broker_id .. "' registered.", cols)
    end
end

--- Delete the selected broker from the registry.
function ConfigUI:_delete_broker()
    local brokers = self._config.brokerRegistry
    if self._broker_selection < 1 or self._broker_selection > #brokers then
        return
    end

    local gpu = self._gpu
    local cols = self._term_cols
    local broker_id = brokers[self._broker_selection]

    local confirmed = UI.confirm_dialog(gpu,
        "Remove broker '" .. broker_id .. "'?", cols)
    if confirmed then
        table.remove(brokers, self._broker_selection)
        self._modified = true
        if self._broker_selection > #brokers then
            self._broker_selection = #brokers
        end
    end
end

--=============================================================================
-- Static: Entry point for supervisor.lua integration
--=============================================================================

--- Main entry point for the config UI. Detects whether this is a first run
--- (no config file) or a reconfiguration, then launches the appropriate UI.
---
--- Returns the final config table that can be passed to Supervisor.new().
--- If the user cancels during first run, returns default config.
---
--- @return table config  Merged config table
function ConfigUI.run_config_ui()
    -- Attempt to load existing config
    local existing = ConfigUI.load_config()

    local instance = ConfigUI.new(existing)

    -- First run or load failure: run wizard
    if not existing then
        instance:run_wizard()
    end

    -- Always run the runtime config UI for review/editing
    instance:run()

    return instance:get_config()
end

--- Quick entry point: run the runtime config UI without wizard.
--- Useful when supervisor.lua detects 'o' key or --config flag.
--- @return table config
function ConfigUI.run_runtime_config()
    local existing = ConfigUI.load_config()
    local instance = ConfigUI.new(existing)
    instance:run()
    return instance:get_config()
end

return ConfigUI
