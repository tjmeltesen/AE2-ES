--=============================================================================
-- src/ui/common.lua
-- AE2-ES Shared UI Widget Library
--
-- Extracted common UI components for both broker and supervisor configuration
-- interfaces. Provides color palettes, text rendering helpers, keyboard input
-- mapping, menu system, and dialog helpers.
--
-- All functions are pure (no OC component calls) so they can be tested in
-- standalone Lua 5.3 as well as on OpenComputers.
--
-- Conventions:
--   - Lua 5.2/5.3 compatible (GTNH OpenComputers)
--   - snake_case for functions, PascalCase for class-like tables
--   - Every function takes an explicit 'gpu' parameter for side-effect-free
--     testing (pass a stub GPU in tests, real GPU at runtime)
--   - No global state: all configuration is passed as parameters
--=============================================================================

local UI = {}

--=============================================================================
-- Color Palette (0xRRGGBB)
--=============================================================================

UI.COLOR = {
    -- Backgrounds
    BG          = 0x000000,   -- black background
    PANEL_BG    = 0x0F0F1A,   -- panel background
    PANEL_BORDER = 0x333355,  -- panel border
    HEADER_BG   = 0x1A1A2E,   -- dark navy header
    SELECTION   = 0x2A2A5A,   -- selected row highlight
    INPUT_BG    = 0x1A1A2E,   -- text input background
    BAR_BG      = 0x222222,   -- bar graph background

    -- Text
    TEXT        = 0xFFFFFF,   -- white primary text
    DIM         = 0x888888,   -- dim / secondary text
    LABEL       = 0xAAAAAA,   -- field labels
    HIGHLIGHT   = 0xFFFF00,   -- yellow highlight
    ERROR       = 0xFF3333,   -- red error text
    SUCCESS     = 0x00FF00,   -- green success text
    WARNING     = 0xFFAA00,   -- orange warning
    INFO        = 0x3399FF,   -- blue info
    DISABLED    = 0x555555,   -- grey disabled

    -- Status
    ACTIVE      = 0x00FF00,   -- green
    STALE       = 0xFFFF00,   -- yellow
    OFFLINE     = 0xFF3333,   -- red
    UNREGISTERED = 0x555555,  -- grey

    -- Machine status
    AVAILABLE   = 0x00AA00,
    LOCKED      = 0xAAAA00,
    PROCESSING  = 0x0088FF,
    FAULTED     = 0xFF0000,

    -- TTD
    TTD_GOOD    = 0x00FF00,
    TTD_WARN    = 0xFFFF00,
    TTD_CRIT    = 0xFF0000,
}

--=============================================================================
-- Key Code Constants (OpenComputers key_down codes)
--=============================================================================

UI.KEY = {
    UP      = 200,
    DOWN    = 208,
    LEFT    = 203,
    RIGHT   = 205,
    ENTER   = 28,
    TAB     = 15,
    ESCAPE  = 1,
    BACKSPACE = 14,
    HOME    = 199,
    END_KEY = 207,
    PGUP    = 201,
    PGDN    = 209,
    F1      = 59,
    F2      = 60,
    F3      = 61,
    F4      = 62,
    F5      = 63,
    F6      = 64,
    F7      = 65,
    F8      = 66,
    F9      = 67,
    F10     = 68,
    DELETE  = 211,
    INSERT  = 210,
}

--=============================================================================
-- Rendering Helpers
--=============================================================================

--- Fill a rectangular region with a background color.
--- @param gpu    GPU component proxy (or mock)
--- @param x, y   Top-left position (1-indexed)
--- @param w, h   Width and height in characters
--- @param color  0xRRGGBB color
function UI.fill_region(gpu, x, y, w, h, color)
    gpu.setBackground(color)
    gpu.fill(x, y, w, h, " ")
end

--- Draw a horizontal rule with a specific character and color.
--- @param gpu    GPU component proxy
--- @param y      Row position
--- @param width  Total width in characters
--- @param color  Color of the rule (default: PANEL_BORDER)
--- @param char   Character to draw (default: 140 = OC horizontal line)
function UI.draw_hr(gpu, y, width, color, char)
    gpu.setBackground(UI.COLOR.PANEL_BG)
    gpu.setForeground(color or UI.COLOR.PANEL_BORDER)
    gpu.set(1, y, string.rep(char or "\\140", width or 80))
end

--- Draw a labelled field: "Label: value" with color-coded label.
--- @param gpu    GPU component proxy
--- @param x, y   Position (1-indexed)
--- @param label  Field label text
--- @param value  Field value text
--- @param val_color  Color for the value (default: TEXT)
function UI.draw_field(gpu, x, y, label, value, val_color)
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.LABEL)
    gpu.set(x, y, label)
    gpu.setForeground(val_color or UI.COLOR.TEXT)
    gpu.set(x + #label, y, tostring(value))
end

--- Draw centered text on a row.
--- @param gpu    GPU component proxy
--- @param y      Row position
--- @param text   Text to center
--- @param width  Total width (default: 80)
--- @param fg     Foreground color (default: TEXT)
--- @param bg     Background color (default: BG)
function UI.draw_centered(gpu, y, text, width, fg, bg)
    width = width or 80
    local x = math.floor((width - #text) / 2) + 1
    if x < 1 then x = 1 end
    gpu.setBackground(bg or UI.COLOR.BG)
    gpu.setForeground(fg or UI.COLOR.TEXT)
    gpu.set(x, y, text)
end

--- Draw a horizontal bar graph.
--- @param gpu      GPU component proxy
--- @param x, y     Top-left position
--- @param width    Total bar width
--- @param level    Current level (0-1 fraction)
--- @param color    Bar fill color
function UI.draw_bar(gpu, x, y, width, level, color)
    local fill = math.max(0, math.min(level or 0, 1.0))
    local filled = math.floor(fill * width)

    -- Background
    gpu.setBackground(UI.COLOR.BAR_BG)
    gpu.fill(x, y, width, 1, " ")

    -- Filled portion
    if filled > 0 then
        gpu.setBackground(color)
        gpu.fill(x, y, filled, 1, " ")
    end
end

--- Clear the entire screen.
--- @param gpu        GPU component proxy
--- @param term_cols  Terminal width (default: 80)
--- @param term_rows  Terminal height (default: 25)
function UI.clear_screen(gpu, term_cols, term_rows)
    term_cols = term_cols or 80
    term_rows = term_rows or 25
    UI.fill_region(gpu, 1, 1, term_cols, term_rows, UI.COLOR.BG)
end

--- Write a status indicator (colored text) at position.
--- @param gpu    GPU component proxy
--- @param x, y   Position
--- @param status Status string
function UI.write_status(gpu, x, y, status)
    local color
    if status == "ACTIVE" or status == "ONLINE" then
        color = UI.COLOR.ACTIVE
    elseif status == "STALE" then
        color = UI.COLOR.STALE
    elseif status == "OFFLINE" then
        color = UI.COLOR.OFFLINE
    else
        color = UI.COLOR.UNREGISTERED
    end
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(color)
    gpu.set(x, y, status)
end

--=============================================================================
-- Color utility functions
--=============================================================================

--- Return the color for a broker status string.
--- @param status string "ACTIVE", "STALE", "OFFLINE", or other
--- @return number 0xRRGGBB
function UI.color_for_status(status)
    if status == "ACTIVE"    then return UI.COLOR.ACTIVE end
    if status == "STALE"     then return UI.COLOR.STALE end
    if status == "OFFLINE"   then return UI.COLOR.OFFLINE end
    return UI.COLOR.UNREGISTERED
end

--- Return the color for a machine status string.
--- @param status string
--- @return number 0xRRGGBB
function UI.color_for_machine_status(status)
    if status == "AVAILABLE"  then return UI.COLOR.AVAILABLE end
    if status == "LOCKED"     then return UI.COLOR.LOCKED end
    if status == "PROCESSING" then return UI.COLOR.PROCESSING end
    if status == "FAULTED"    then return UI.COLOR.FAULTED end
    return UI.COLOR.DIM
end

--- Return the color for a TTD state.
--- @param critical  boolean
--- @param depletion_secs  number or nil
--- @return number 0xRRGGBB
function UI.color_for_ttd(critical, depletion_secs)
    if critical or (depletion_secs and depletion_secs > 0 and depletion_secs < 60) then
        return UI.COLOR.TTD_CRIT
    elseif depletion_secs and depletion_secs > 0 and depletion_secs < 300 then
        return UI.COLOR.TTD_WARN
    end
    return UI.COLOR.TTD_GOOD
end

--=============================================================================
-- Formatting Helpers
--=============================================================================

--- Format TTD seconds into a display string.
--- @param secs number|nil
--- @return string
function UI.format_ttd(secs)
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

--- Format elapsed seconds into a human-readable string.
--- @param elapsed number|nil
--- @return string
function UI.format_elapsed(elapsed)
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

--- Truncate a string to max_len, appending "..." if truncated.
--- @param s        string
--- @param max_len  number (default: 20)
--- @return string
function UI.truncate(s, max_len)
    max_len = max_len or 20
    if #s <= max_len then
        return s
    end
    if max_len <= 3 then
        return s:sub(1, max_len)
    end
    return s:sub(1, max_len - 3) .. "..."
end

--=============================================================================
-- Deep copy helper (for table merging)
--=============================================================================

--- Deep copy a value (handles nested tables, scalars, nil).
--- @param t any
--- @return any
function UI.deep_copy(t)
    if type(t) ~= "table" then return t end
    local result = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            result[k] = UI.deep_copy(v)
        else
            result[k] = v
        end
    end
    return result
end

--=============================================================================
-- Menu System
--=============================================================================

--- Display a simple text menu and return the user's selection.
---
--- Renders a list of options with index numbers. The user navigates with
--- up/down arrows and confirms with Enter, or presses a number key (1-9)
--- for direct selection. Returns nil if Escape is pressed.
---
--- @param gpu        GPU component proxy
--- @param title      Menu title string
--- @param options    Array of { label = string, ... } tables
--- @param x, y       Top-left position of the menu
--- @param width      Menu width (default: 60)
--- @param term_cols  Terminal width (default: 80)
--- @return table|nil  The selected option row, or nil on cancel
function UI.show_menu(gpu, title, options, x, y, width, term_cols)
    width = width or 60
    term_cols = term_cols or 80
    x = x or math.floor((term_cols - width) / 2) + 1
    y = y or 3

    local selection = 1
    local offset = 0
    local max_visible = term_cols - y - 2
    if max_visible < 1 then max_visible = 1 end
    if max_visible > #options then max_visible = #options end
    local pageable = #options > max_visible

    while true do
        -- Redraw menu
        UI.clear_screen(gpu, term_cols, term_cols)
        local cursor = y

        -- Title
        UI.draw_centered(gpu, cursor, title, term_cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)
        cursor = cursor + 2

        -- Options
        for i = offset + 1, math.min(offset + max_visible, #options) do
            local opt = options[i]
            local is_selected = (i == selection)
            local line
            if is_selected then
                line = string.format(" > %2d. %s", i, opt.label or "")
            else
                line = string.format("   %2d. %s", i, opt.label or "")
            end

            gpu.setBackground(is_selected and UI.COLOR.SELECTION or UI.COLOR.BG)
            gpu.setForeground(is_selected and UI.COLOR.HIGHLIGHT or UI.COLOR.TEXT)
            gpu.set(x, cursor, line:sub(1, width))
            cursor = cursor + 1
        end

        -- Page indicator
        if pageable then
            gpu.setBackground(UI.COLOR.BG)
            gpu.setForeground(UI.COLOR.DIM)
            local page_info = string.format("Page %d/%d (PgUp/PgDn)",
                math.floor(offset / max_visible) + 1,
                math.ceil(#options / max_visible))
            gpu.set(x, cursor + 1, page_info)
        end

        -- Bottom hint
        gpu.setBackground(UI.COLOR.BG)
        gpu.setForeground(UI.COLOR.DIM)
        gpu.set(x, cursor + 2, "Arrow keys: navigate   Enter: select   Esc: cancel")

        -- Get input
        local key = {event.pull()}
        if key[1] == "key_down" then
            local char = key[3]
            local code = key[4]

            -- Number key direct selection (1-9)
            if char and char >= 49 and char <= 57 then
                local idx = char - 48
                if idx <= #options then
                    selection = idx
                    return options[selection]
                end
            end

            if code == UI.KEY.UP then
                selection = selection - 1
                if selection < 1 then selection = #options end
                -- Adjust scroll if needed
                if selection <= offset then
                    offset = math.max(0, selection - 1)
                end
            elseif code == UI.KEY.DOWN then
                selection = selection + 1
                if selection > #options then selection = 1 end
                if selection > offset + max_visible then
                    offset = selection - max_visible
                end
            elseif code == UI.KEY.PGUP then
                selection = math.max(1, selection - max_visible)
                offset = math.max(0, selection - 1)
            elseif code == UI.KEY.PGDN then
                selection = math.min(#options, selection + max_visible)
                if selection > offset + max_visible then
                    offset = selection - max_visible
                end
            elseif code == UI.KEY.ENTER then
                return options[selection]
            elseif code == UI.KEY.ESCAPE then
                return nil
            end
        elseif key[1] == "interrupted" then
            return nil
        end
    end
end

--=============================================================================
-- Dialog System
--=============================================================================

--- Show a yes/no confirmation dialog.
--- @param gpu        GPU component proxy
--- @param message    Confirmation message
--- @param term_cols  Terminal width (default: 80)
--- @return boolean   true for yes, false for no
function UI.confirm_dialog(gpu, message, term_cols)
    term_cols = term_cols or 80
    local width = math.min(#message + 8, 60)
    local x = math.floor((term_cols - width) / 2) + 1
    local y = 10

    UI.clear_screen(gpu, term_cols, term_cols)

    -- Dialog box background
    UI.fill_region(gpu, x - 2, y - 1, width + 4, 5, UI.COLOR.HEADER_BG)
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    gpu.set(x - 2, y - 1, string.rep("\\140", width + 4))
    gpu.set(x - 2, y + 3, string.rep("\\140", width + 4))

    -- Message
    UI.draw_centered(gpu, y, message, term_cols, UI.COLOR.TEXT, UI.COLOR.HEADER_BG)

    -- Options
    local selection = 1  -- 1 = Yes, 2 = No
    while true do
        local yes_str = (selection == 1) and " > Yes < " or "   Yes   "
        local no_str  = (selection == 2) and " > No  < " or "   No    "
        local line = yes_str .. "    " .. no_str

        gpu.setBackground(UI.COLOR.HEADER_BG)
        gpu.setForeground(UI.COLOR.TEXT)
        gpu.set(math.floor((term_cols - #line) / 2) + 1, y + 2, line)

        local key = {event.pull()}
        if key[1] == "key_down" then
            local char = key[3]
            local code = key[4]

            if code == UI.KEY.LEFT or code == UI.KEY.RIGHT then
                selection = (selection == 1) and 2 or 1
            elseif code == UI.KEY.ENTER then
                return selection == 1
            elseif code == UI.KEY.ESCAPE then
                return false  -- Escape = No
            elseif char == 121 then  -- 'y'
                return true
            elseif char == 110 then  -- 'n'
                return false
            end
        elseif key[1] == "interrupted" then
            return false
        end
    end
end

--- Show a text input dialog and return the entered string.
--- @param gpu        GPU component proxy
--- @param prompt     Input prompt text
--- @param default    Default value (pre-filled)
--- @param term_cols  Terminal width (default: 80)
--- @return string|nil  The entered text, or nil if cancelled
function UI.input_dialog(gpu, prompt, default, term_cols)
    term_cols = term_cols or 80
    default = default or ""
    local width = 50
    local x = math.floor((term_cols - width) / 2) + 1
    local y = 11

    UI.clear_screen(gpu, term_cols, term_cols)

    local input = default
    local cursor_pos = #input + 1

    while true do
        -- Dialog box
        UI.fill_region(gpu, x - 2, y - 1, width + 4, 5, UI.COLOR.HEADER_BG)
        gpu.setForeground(UI.COLOR.PANEL_BORDER)
        gpu.set(x - 2, y - 1, string.rep("\\140", width + 4))
        gpu.set(x - 2, y + 3, string.rep("\\140", width + 4))

        -- Prompt
        UI.draw_centered(gpu, y, prompt, term_cols, UI.COLOR.LABEL, UI.COLOR.HEADER_BG)

        -- Input field
        local display = input:sub(1, width - 4)
        gpu.setBackground(UI.COLOR.INPUT_BG)
        gpu.setForeground(UI.COLOR.TEXT)
        gpu.set(x, y + 1, display .. string.rep(" ", width - 4 - #display))

        -- Cursor
        gpu.setBackground(UI.COLOR.INPUT_BG)
        gpu.setForeground(UI.COLOR.HIGHLIGHT)
        gpu.set(x + math.min(cursor_pos - 1, width - 4), y + 1, "_")

        -- Hint
        gpu.setBackground(UI.COLOR.BG)
        gpu.setForeground(UI.COLOR.DIM)
        gpu.set(1, y + 4, "Type value, Enter to confirm, Esc to cancel")

        local key = {event.pull()}
        if key[1] == "key_down" then
            local char = key[3]
            local code = key[4]

            if code == UI.KEY.ENTER then
                return input
            elseif code == UI.KEY.ESCAPE then
                return nil
            elseif code == UI.KEY.BACKSPACE then
                if #input > 0 then
                    input = input:sub(1, #input - 1)
                    cursor_pos = math.max(1, cursor_pos - 1)
                end
            elseif code == UI.KEY.DELETE then
                if cursor_pos <= #input then
                    input = input:sub(1, cursor_pos - 1) .. input:sub(cursor_pos + 1)
                end
            elseif code == UI.KEY.HOME then
                cursor_pos = 1
            elseif code == UI.KEY.END_KEY then
                cursor_pos = #input + 1
            elseif code == UI.KEY.LEFT then
                cursor_pos = math.max(1, cursor_pos - 1)
            elseif code == UI.KEY.RIGHT then
                cursor_pos = math.min(#input + 1, cursor_pos + 1)
            elseif char and char >= 32 then
                -- Printable ASCII
                input = input:sub(1, cursor_pos - 1) .. string.char(char) .. input:sub(cursor_pos)
                cursor_pos = cursor_pos + 1
                -- Cap at reasonable length
                if #input > 255 then
                    input = input:sub(1, 255)
                    cursor_pos = math.min(cursor_pos, 256)
                end
            end
        elseif key[1] == "interrupted" then
            return nil
        end
    end
end

--- Show a message/info dialog with an OK button.
--- @param gpu        GPU component proxy
--- @param title      Dialog title
--- @param message    Multi-line message (table of strings) or single string
--- @param term_cols  Terminal width (default: 80)
function UI.message_dialog(gpu, title, message, term_cols)
    term_cols = term_cols or 80
    local lines
    if type(message) == "table" then
        lines = message
    else
        lines = {message}
    end

    local width = 60
    local height = #lines + 5
    local x = math.floor((term_cols - width) / 2) + 1
    local start_y = math.floor((25 - height) / 2)

    UI.clear_screen(gpu, term_cols, term_cols)

    -- Dialog box
    local box_x = x - 2
    local box_y = start_y - 1
    local box_w = width + 4
    local box_h = height + 2

    UI.fill_region(gpu, box_x, box_y, box_w, box_h, UI.COLOR.HEADER_BG)
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    gpu.set(box_x, box_y, string.rep("\\140", box_w))
    gpu.set(box_x, box_y + box_h - 1, string.rep("\\140", box_w))

    -- Title
    UI.draw_centered(gpu, start_y, title, term_cols, UI.COLOR.HIGHLIGHT, UI.COLOR.HEADER_BG)

    -- Message lines
    for i, line in ipairs(lines) do
        UI.draw_centered(gpu, start_y + 1 + i, line, term_cols, UI.COLOR.TEXT, UI.COLOR.HEADER_BG)
    end

    -- OK button
    gpu.setBackground(UI.COLOR.HEADER_BG)
    gpu.setForeground(UI.COLOR.DIM)
    gpu.set(math.floor((term_cols - 6) / 2) + 1, start_y + height, " [ OK] ")

    -- Wait for Enter or any key
    local key = {event.pull()}
    while key[1] ~= "key_down" and key[1] ~= "interrupted" do
        key = {event.pull()}
    end
end

--=============================================================================
-- Tabbed Interface Helpers
--=============================================================================

--- Draw a tab bar at the top of the screen.
--- @param gpu        GPU component proxy
--- @param tabs       Array of tab label strings
--- @param active_idx 1-indexed active tab index
--- @param x, y       Position
--- @param term_cols  Terminal width (default: 80)
function UI.draw_tabs(gpu, tabs, active_idx, x, y, term_cols)
    term_cols = term_cols or 80
    x = x or 1
    y = y or 1

    local cursor_x = x

    for i, tab in ipairs(tabs) do
        local is_active = (i == active_idx)
        local padding = 2
        local tab_text = (is_active and "[" or " ") .. tab .. (is_active and "]" or " ")
        local fg = is_active and UI.COLOR.HIGHLIGHT or UI.COLOR.DIM
        local bg = is_active and UI.COLOR.HEADER_BG or UI.COLOR.BG

        gpu.setBackground(bg)
        gpu.setForeground(fg)
        gpu.set(cursor_x, y, tab_text)
        cursor_x = cursor_x + #tab_text

        -- Separator between tabs
        if i < #tabs then
            gpu.setBackground(UI.COLOR.BG)
            gpu.setForeground(UI.COLOR.PANEL_BORDER)
            gpu.set(cursor_x, y, " ")
            cursor_x = cursor_x + 1
        end
    end

    -- Fill remaining tab bar area
    gpu.setBackground(UI.COLOR.BG)
    gpu.setForeground(UI.COLOR.PANEL_BORDER)
    if cursor_x <= term_cols then
        gpu.fill(x + cursor_x - 1, y, term_cols - cursor_x + 1, 1, "\\140")
    end
end

--=============================================================================
-- List/Table Helpers
--=============================================================================

--- Render a paginated scrolling list with headers.
--- @param gpu        GPU component proxy
--- @param rows       Array of row data (each is a table with _label or string)
--- @param x, y       Top-left position
--- @param width      Content width
--- @param max_rows   Number of visible rows
--- @param selection  Current 1-based selection index
--- @param scroll     Current scroll offset
--- @param header     Optional header string (rendered above list)
--- @return selection, scroll (updated indices)
function UI.draw_scroll_list(gpu, rows, x, y, width, max_rows, selection, scroll, header)
    if not rows or #rows == 0 then
        gpu.setBackground(UI.COLOR.BG)
        gpu.setForeground(UI.COLOR.DIM)
        gpu.set(x, y, header and (header .. " (empty)") or "(empty)")
        return selection, scroll
    end

    -- Ensure scroll position is valid
    if scroll < 0 then scroll = 0 end
    if selection < 1 then selection = 1 end
    if selection > #rows then selection = #rows end
    if scroll > #rows - max_rows then scroll = math.max(0, #rows - max_rows) end
    if selection <= scroll then selection = scroll + 1 end
    if selection > scroll + max_rows then selection = scroll + max_rows end

    local cursor = y

    -- Header
    if header then
        gpu.setBackground(UI.COLOR.HEADER_BG)
        gpu.setForeground(UI.COLOR.LABEL)
        gpu.set(x, cursor, header:sub(1, width))
        cursor = cursor + 1
    end

    -- Rows
    for i = scroll + 1, math.min(scroll + max_rows, #rows) do
        local row = rows[i]
        local label
        if type(row) == "string" then
            label = row
        elseif type(row) == "table" then
            label = row._label or tostring(row[1] or "")
        else
            label = tostring(row)
        end

        local is_selected = (i == selection)
        local prefix = is_selected and "> " or "  "

        gpu.setBackground(is_selected and UI.COLOR.SELECTION or UI.COLOR.BG)
        gpu.setForeground(is_selected and UI.COLOR.HIGHLIGHT or UI.COLOR.TEXT)
        gpu.set(x, cursor, (prefix .. label):sub(1, width))

        cursor = cursor + 1
    end

    -- Clear remaining rows
    for r = cursor, y + max_rows do
        gpu.setBackground(UI.COLOR.BG)
        gpu.fill(x, r, width, 1, " ")
    end

    return selection, scroll
end

return UI
