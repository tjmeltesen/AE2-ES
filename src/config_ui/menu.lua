-- config_ui/menu.lua -- config menu + field editors
local ConfigUI = require("src.config_ui.wizard")
-- ===========================================================================
-- Runtime configuration menu
-- ===========================================================================

--- Run the main runtime configuration menu.
-- Shows current config and allows modification of all settings.
function ConfigUI:runConfigMenu()
  -- Ensure config exists
  self:_ensureConfig()
  if not self._config then
    self:_showMessage("No configuration loaded. Run setup wizard first.")
    return
  end

  local running = true
  while running do
    self:_clear()
    self:_drawTitle("Exec Broker Configuration Manager")
    self:_writeLine(3, string.format("Broker: %s", self._config.brokerId or "(not set)"), COLOR_CYAN)
    self:_separator(4)

    local machineCount = #(self._config.machines or {})

    local options = {
      { label = "Broker Identity",              action = "broker_id" },
      { label = "Modem & Telemetry",            action = "modem" },
      { label = "Redstone I/O Block",           action = "redstone" },
      { label = "ME Controller (Central Buffer)",  action = "me_controller" },
      { label = string.format("Machines [%d]", machineCount), action = "machines" },
      { label = "Timing & Queue",               action = "timing" },
      { label = "Test Connectivity",            action = "test" },
      { label = "Connection status",            action = "status" },
      { label = "Import Configuration",         action = "import" },
      { label = "Export Configuration",         action = "export" },
      { label = "Reset to Defaults",            action = "reset" },
      { label = "Save & Exit",                  action = "save_exit" },
      { label = "Exit (discard changes)",       action = "exit" },
    }

    local action = self:_menuLoop("Main Menu", options)

    if action == nil or action == "exit" then
      running = false
    elseif action == "save_exit" then
      if self:_confirm("Save configuration", true) then
        local ok, err = self:saveConfig()
        if ok then
          self:_showMessage("Configuration saved.")
        else
          self:_showMessage("Save failed: " .. tostring(err))
        end
      end
      running = false
    elseif action == "broker_id" then
      self:_editBrokerId()
    elseif action == "modem" then
      self:_editModem()
    elseif action == "redstone" then
      self:_editRedstone()
    elseif action == "me_controller" then
      self:_editMEController()
    elseif action == "machines" then
      self:_editMachines()
    elseif action == "timing" then
      self:_editTiming()
    elseif action == "test" then
      self:_runConnectivityTest()
    elseif action == "status" then
      self:_showConnectionStatus()
    elseif action == "import" then
      self:_importConfig()
    elseif action == "export" then
      self:_showConfigSummary()
      self:_pressAnyKey()
    elseif action == "reset" then
      if self:_confirm("Reset all settings to defaults? This cannot be undone.", false) then
        self:resetConfig()
        self:_showMessage("Configuration reset to defaults.")
      end
    end
    os.sleep(0)
  end
end

-- ===========================================================================
-- Individual setting editors
-- ===========================================================================

--- Edit broker ID.
function ConfigUI:_editBrokerId()
  self:_clear()
  self:_drawTitle("Broker Identity")
  self:_writeLine(3, "Current broker ID: " .. tostring(self._config.brokerId), COLOR_CYAN)
  local id = self:_readLine("New broker ID (or Enter to keep): ")
  if id and #id > 0 then
    self._config.brokerId = id
  end
end

--- Edit modem and telemetry settings.
function ConfigUI:_editModem()
  self:_clear()
  self:_drawTitle("Modem & Telemetry")
  self:_writeLine(3, "Current settings:", COLOR_CYAN)
  self:_writeLine(4, "  Modem address: " .. (self._config.modemAddress ~= "" and self._config.modemAddress or "(none)"), self:_statusColor(self._config.modemAddress))
  self:_writeLine(5, "  Telemetry port: " .. tostring(self._config.telemetryPort))
  self:_writeLine(6, "")

  local addr = self:_readLine("Modem component address (or blank to keep): ")
  if addr and #addr > 0 then
    self._config.modemAddress = addr
  end

  local port = self:_readNumber("Telemetry port", self._config.telemetryPort, 1, 65535)
  self._config.telemetryPort = port
end

--- Edit redstone I/O block address and side.
function ConfigUI:_editRedstone()
  self:_clear()
  self:_drawTitle("Redstone I/O Block")
  self:_writeLine(3, "Current address: " .. (self._config.redstoneAddress ~= "" and self._config.redstoneAddress or "(not configured)"), self:_statusColor(self._config.redstoneAddress))
  self:_writeLine(4, "Current side: " .. tostring(self._config.redstoneSide or 5))
  self:_writeLine(5, "Sides: 0=bottom, 1=top, 2=back, 3=front, 4=left, 5=right", COLOR_DIM)
  self:_writeLine(6, "")
  local addr = self:_readLine("Redstone component address (or blank to keep): ")
  if addr and #addr > 0 then
    self._config.redstoneAddress = addr
  end
  local side = self:_readNumber("Redstone lock output side", self._config.redstoneSide or 5, 0, 5)
  self._config.redstoneSide = side
end

--- Edit ME Controller address (central buffer).
function ConfigUI:_editMEController()
  self:_clear()
  self:_drawTitle("ME Controller (Central Buffer)")
  self:_writeLine(3, "Current: " .. (self._config.meControllerAddr ~= "" and self._config.meControllerAddr or "(not configured)"), self:_statusColor(self._config.meControllerAddr))
  self:_writeLine(4, "Enter the address of your ME Controller.")
  local addr = self:_readLine("ME Controller address (or blank to keep): ")
  if addr ~= "" then
    self._config.meControllerAddr = addr
  end
end

--- Edit machine list.
function ConfigUI:_editMachines()
  local running = true
  while running do
    self:_clear()
    self:_drawTitle("Machine Configuration")

    local count = #(self._config.machines or {})
    self:_writeLine(3, string.format("Total machines: %d", count), COLOR_CYAN)
    self:_separator(4)

    if count == 0 then
      self:_writeLine(5, "No machines configured.", COLOR_YELLOW)
    else
      for i, lane in ipairs(self._config.machines) do
        local addr = lane.machineAddr or lane.address or ""
        local mt = (self._config.machineTypes and self._config.machineTypes[addr]) or "basic"
        local mtLabel = ({
          [1] = "[Basic]", [4] = "[Fluid]", [32] = "[Steam]", [128] = "[Multi]"
        })[mt] or "[Basic]"

        local short = addr
        if #short > 32 then
          short = addr:sub(1, 30) .. ".."
        end
        self:_writeLine(4 + i, string.format("  %2d. %s %s", i, mtLabel, short), COLOR_GRAY)
      end
    end

    self:_separator(self._height - 4)

    local options = {
      { label = "Add machine",        action = "add" },
      { label = "Remove machine",    action = "remove" },
      { label = "Edit machine type",  action = "type" },
      { label = "Reorder machines",  action = "reorder" },
      { label = "Detect machines",   action = "detect" },
      { label = "Back",              action = "back" },
    }

    local action = self:_menuLoop("Machine Options", options)
    if action == nil or action == "back" then
      running = false
    elseif action == "add" then
      local addr = self:_readLine("New machine component address: ")
      if addr and #addr > 0 then
        local laneNum = #(self._config.machines or {}) + 1
        table.insert(self._config.machines, {
          laneId = "Lane " .. tostring(laneNum),
          machineAddr = addr,
        })
        self:_setupMachineType(addr)
      end
    elseif action == "remove" then
      if count > 0 then
        local idx = self:_readNumber("Machine number to remove", 1, 1, count)
        local removed = table.remove(self._config.machines, idx)
        if self._config.machineTypes then
          self._config.machineTypes[removed] = nil
        end
        self:_showMessage(string.format("Removed machine %d (%s)", idx, removed:sub(1, 16)))
      end
    elseif action == "type" then
      if count > 0 then
        local idx = self:_readNumber("Machine number", 1, 1, count)
        self:_setupMachineType(self._config.machines[idx])
      end
    elseif action == "reorder" then
      if count >= 2 then
        self:_reorderMachines()
      end
    elseif action == "detect" then
      self:_detectAndAddMachines()
    end
  end
end

--- UI for reordering machines.
function ConfigUI:_reorderMachines()
  local machines = self._config.machines
  if #machines < 2 then
    self:_showMessage("Need at least 2 machines to reorder.")
    return
  end

  self:_clear()
  self:_drawTitle("Reorder Machines")
  for _, lane in ipairs(machines) do
      local addr = lane.machineAddr or lane.address
    self:_writeLine(2 + i, string.format("  %d. %s", i, addr), COLOR_CYAN)
  end

  local fromIdx = self:_readNumber("Move machine number", 1, 1, #machines)
  local toIdx = self:_readNumber("To position", 1, 1, #machines)

  if fromIdx ~= toIdx then
    local item = table.remove(machines, fromIdx)
    table.insert(machines, toIdx, item)
    self:_showMessage(string.format("Moved machine %d to position %d", fromIdx, toIdx))
  end
end

--- Detect and add new machines from the component list.
function ConfigUI:_detectAndAddMachines()
  local detected = self:detectComponents()
  local existing = {}
  for _, lane in ipairs(self._config.machines) do
    local addr = lane.machineAddr or lane.address
    existing[addr] = true
  end

  local added = 0
  for _, entry in ipairs(detected.gtMachines) do
    if not existing[entry.address] then
      if self:_confirm(string.format("Add %s (%s)", entry.type, entry.address:sub(1, 8).."..."), true) then
        local laneNum = #(self._config.machines or {}) + 1
        table.insert(self._config.machines, {
          laneId = "Lane " .. tostring(laneNum),
          machineAddr = entry.address,
        })
        self:_setupMachineType(entry.address)
        added = added + 1
      end
    end
  end

  if added == 0 then
    self:_showMessage("No new machines found to add.")
  else
    self:_showMessage(string.format("Added %d new machine(s).", added))
  end
end

--- Edit timing parameters.
function ConfigUI:_editTiming()
  self:_clear()
  self:_drawTitle("Timing & Queue Configuration")
  self:_writeLine(3, "Current settings:", COLOR_CYAN)
  self:_writeLine(4, "  Poll Interval:      " .. tostring(self._config.pollInterval) .. "s")
  self:_writeLine(5, "  Heartbeat Interval: " .. tostring(self._config.heartbeatInterval) .. "s")
  self:_writeLine(6, "  Debounce Window:    " .. tostring(self._config.debounceWindow) .. "s")
  self:_writeLine(7, "  Queue Max Size:     " .. tostring(self._config.queueSize))

  self._config.pollInterval = self:_readNumber("Poll interval (seconds)", self._config.pollInterval, 0.05, 60)
  self._config.heartbeatInterval = self:_readNumber("Heartbeat interval (seconds)", self._config.heartbeatInterval, 0.1, 300)
  self._config.debounceWindow = self:_readNumber("Buffer debounce window (seconds)", self._config.debounceWindow, 0.1, 30)
  self._config.queueSize = self:_readNumber("Job queue max size", self._config.queueSize, 1, 1000)
end

--- Edit HAL side mappings.
-- (HAL side mappings removed — sides are per-lane now)

-- ===========================================================================
-- Connectivity testing
-- ===========================================================================

return ConfigUI
