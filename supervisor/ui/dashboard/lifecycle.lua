-- dashboard/lifecycle.lua -- constructor, start/stop, polling
local Dashboard = require("supervisor.ui.dashboard.helpers")
function Dashboard.new(dependencies)
    if type(dependencies) ~= "table" then
        return nil, "dashboard dependencies table is required"
    end
    for _, name in ipairs({ "subscriber", "matrix", "ttd", "alerts" }) do
        local err = validate_dependency(name, dependencies[name])
        if err then
            return nil, err
        end
    end

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

    self.subscriber = dependencies.subscriber
    self.matrix = dependencies.matrix
    self.ttd = dependencies.ttd
    self.alerts = dependencies.alerts

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

    -- Log viewer state
    self._logViewActive = false           -- toggle log viewer overlay
    self._logScroll = 0                   -- scroll offset in log viewer
    self._logFilterSeverity = nil         -- severity filter (nil = all)
    self._logSearchText = ""              -- text search in log viewer
    self._logSearchActive = false         -- if true, next keypress builds search
    self._logSearchBuffer = ""            -- search text being typed
  
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
-- event.pull(), mirroring the canonical Supervisor's clean-exit pattern.
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

return Dashboard
