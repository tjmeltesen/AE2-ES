-- dashboard/input.lua -- keyboard input + navigation
local Dashboard = require("supervisor.ui.dashboard.lifecycle")
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

    -- Log viewer navigation (overrides panel navigation when active)
    if self._logViewActive then
        if code == 200 then  -- Up arrow
            self._logScroll = math.max(0, self._logScroll - 1)
            self._last_frame_dirty = true
            return
        elseif code == 208 then  -- Down arrow
            self._logScroll = self._logScroll + 1
            self._last_frame_dirty = true
            return
        elseif code == 201 then  -- Page Up
            self._logScroll = math.max(0, self._logScroll - 20)
            self._last_frame_dirty = true
            return
        elseif code == 209 then  -- Page Down
            self._logScroll = self._logScroll + 20
            self._last_frame_dirty = true
            return
        end
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
    elseif upper == "L" then
        -- Toggle log viewer
        self._logViewActive = not self._logViewActive
        self._logScroll = 0
        self._last_frame_dirty = true
        -- Clear flash indicator when entering log view
        if self.subscriber and self.subscriber._loggerAlertFlash then
            self.subscriber._loggerAlertFlash = nil
        end
    elseif upper == "S" and self._logViewActive then
        -- Cycle severity filter in log viewer
        local severities = { "ALL", "CRITICAL", "ERROR", "WARN", "INFO", "DEBUG" }
        local current_idx = 1
        if self._logFilterSeverity then
            for i, s in ipairs(severities) do
                if s == self._logFilterSeverity then
                    current_idx = i
                    break
                end
            end
        end
        current_idx = current_idx + 1
        if current_idx > #severities then current_idx = 1 end
        self._logFilterSeverity = (severities[current_idx] == "ALL") and nil or severities[current_idx]
        self._logScroll = 0
        self._last_frame_dirty = true
    elseif upper == "/" and self._logViewActive then
        -- Enter search mode
        self._logSearchActive = true
        self._logSearchBuffer = ""
        self._last_frame_dirty = true
    elseif code == 28 then  -- Enter key
        if self._logSearchActive then
            -- Commit search
            self._logSearchText = self._logSearchBuffer
            self._logSearchActive = false
            self._logScroll = 0
            self._last_frame_dirty = true
            return
        end
        self:activate()
        self._last_frame_dirty = true
        return
    elseif self._logSearchActive then
        -- Building search text
        if code == 14 then  -- Backspace
            self._logSearchBuffer = self._logSearchBuffer:sub(1, -2)
            self._last_frame_dirty = true
        elseif char then
            self._logSearchBuffer = self._logSearchBuffer .. char
            self._last_frame_dirty = true
        end
        return
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

return Dashboard
