-- dashboard/render.lua -- frame + header + panel rendering
local Dashboard = require("supervisor.ui.dashboard.input")
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
    if self._logViewActive then
      self:render_log_viewer()
    else
      self:render_header()
      self:render_broker_panel()
      self:render_matrix_panel()
      self:render_alert_panel()
      self:render_ttd_panel()
    end

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

    -- Flash alert indicator on ERROR/CRITICAL
    local flashAlert = self.subscriber and self.subscriber._loggerAlertFlash
    if flashAlert and self.flash_on then
        gpu.setBackground(COLOR_HEADER_BG)
        gpu.setForeground(COLOR_CRITICAL)
        gpu.set(TERM_COLS - #time_str - 12, y, " [!ALERT!] ")
    end
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

--===========================================================================
-- Log Viewer Panel (full-screen overlay, toggled with L key)
--===========================================================================
function Dashboard:render_log_viewer()
    local gpu = self.gpu

    -- Clear entire content area
    fill_region(gpu, 1, 1, TERM_COLS, TERM_ROWS, COLOR_BG)

    -- Title bar (row 1)
    gpu.setBackground(COLOR_HEADER_BG)
    gpu.setForeground(COLOR_TEXT)
    local filter_label = self._logFilterSeverity or "ALL"
    local search_label = (self._logSearchText ~= "") and (" /" .. self._logSearchText .. "/") or ""
    local title = string.format(" LOG VIEWER [Filter: %s]%s", filter_label, search_label)
    gpu.set(1, 1, title:sub(1, TERM_COLS - 1))

    -- Keybind hints (right side of title bar)
    gpu.setBackground(COLOR_HEADER_BG)
    gpu.setForeground(COLOR_DIM)
    gpu.set(TERM_COLS - 50, 1, "[L]Back [S]Filter [/]Search [Up/Dn]Scroll")

    -- Separator
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_PANEL_BORDER)
    gpu.set(1, 2, string.rep("\140", TERM_COLS))

    -- Column header (row 3)
    gpu.setBackground(COLOR_PANEL_BG)
    gpu.setForeground(COLOR_DIM)
    gpu.set(1, 3, " #  TIME          SEVERITY   ORIGIN               MESSAGE")
    gpu.setForeground(COLOR_PANEL_BORDER)
    gpu.set(1, 4, string.rep("\140", TERM_COLS))

    -- Get log entries from supervisor
    local entries = {}
    if self.subscriber and self.subscriber.getLog then
        entries = self.subscriber:getLog()
    end

    -- Apply severity filter
    if self._logFilterSeverity then
        local filtered = {}
        for _, e in ipairs(entries) do
            if e.level == self._logFilterSeverity then
                table.insert(filtered, e)
            end
        end
        entries = filtered
    end

    -- Apply search filter
    if self._logSearchText and self._logSearchText ~= "" then
        local q = self._logSearchText:lower()
        local filtered = {}
        for _, e in ipairs(entries) do
            local msg = (e.message or ""):lower()
            if msg:find(q, 1, true) then
                table.insert(filtered, e)
            end
        end
        entries = filtered
    end

    -- Render log entries (rows 5-24 = 20 visible rows)
    local visible_rows = 20
    local log_y = 5

    for i = 1, visible_rows do
        local data_idx = self._logScroll + i
        local row_y = log_y - 1 + i

        if data_idx <= #entries then
            local entry = entries[data_idx]

            -- Format timestamp
            local ts
            if entry.timestamp then
                local t = entry.timestamp
                local h = math.floor(t / 3600) % 24
                local m = math.floor((t % 3600) / 60)
                local s = math.floor(t % 60)
                ts = string.format("%02d:%02d:%02d", h, m, s)
            else
                ts = "--:--:--"
            end

            -- Severity color
            local sev_color = color_for_alert_severity(entry.level)

            -- Background
            local row_bg = COLOR_PANEL_BG
            fill_region(gpu, 1, row_y, TERM_COLS, 1, row_bg)

            -- Row number
            gpu.setBackground(row_bg)
            gpu.setForeground(COLOR_DIM)
            gpu.set(1, row_y, string.format("%-4d", entry.id or data_idx))

            -- Timestamp
            gpu.setForeground(COLOR_DIM)
            gpu.set(5, row_y, ts)

            -- Severity
            gpu.setForeground(sev_color)
            gpu.set(14, row_y, string.format("%-10s", entry.level or "INFO"))

            -- Origin (parse from message for supervisor log format "[brokerId] msg")
            local origin = ""
            local display_message = entry.message or ""
            local origin_end = display_message:find("] ")
            if origin_end and display_message:sub(1, 1) == "[" then
                origin = display_message:sub(2, origin_end - 1)
                display_message = display_message:sub(origin_end + 2)
            end

            gpu.setForeground(origin ~= "" and COLOR_TEXT or COLOR_DIM)
            gpu.set(24, row_y, string.format("%-20s", origin:sub(1, 20)))

            -- Message
            gpu.setForeground(COLOR_TEXT)
            local msg_width = TERM_COLS - 45
            gpu.set(45, row_y, display_message:sub(1, msg_width))

        else
            -- Empty row
            fill_region(gpu, 1, row_y, TERM_COLS, 1, COLOR_PANEL_BG)
            gpu.setBackground(COLOR_PANEL_BG)
            gpu.setForeground(COLOR_DIM)
            if i == 1 and #entries == 0 then
                gpu.set(1, row_y, " No log entries" .. (self._logFilterSeverity and (" (filter: " .. self._logFilterSeverity .. ")") or ""))
            end
        end
    end

    -- Status bar (row 25)
    fill_region(gpu, 1, TERM_ROWS, TERM_COLS, 1, COLOR_HEADER_BG)
    gpu.setBackground(COLOR_HEADER_BG)
    gpu.setForeground(COLOR_DIM)
    local status = string.format(" %d entries | scroll: %d", #entries, self._logScroll)
    gpu.set(1, TERM_ROWS, status)

    -- Search input bar
    if self._logSearchActive then
        gpu.setBackground(COLOR_SELECTION)
        gpu.setForeground(COLOR_TEXT)
        gpu.set(45, TERM_ROWS, string.format("Search: %s_", self._logSearchBuffer))
    end
end



return Dashboard
