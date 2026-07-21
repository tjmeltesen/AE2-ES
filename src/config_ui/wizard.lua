-- config_ui/wizard.lua -- setup wizard + menu loop
local ConfigUI = require("src.config_ui.build")
-- ===========================================================================
-- Menu system
-- ===========================================================================

--- Display a menu with numbered options and get user selection.
-- @param title    string  menu title
-- @param options  table   array of { label, action, status? } entries
--   label  — display text
--   action — callback or "exit" to stop, "back" to go back
--   status — optional status key ("ok", "missing", "unconfigured")
-- @return string or nil  selected action, or nil on exit
function ConfigUI:_menuLoop(title, options)
  local scrollOffset = 0
  local maxVisible = self._height - 6  -- title, separator, status line, help

  local function redrawMenu()
    self:_clear()
    self:_drawTitle(title)

    -- Draw visible options
    local y = 3
    local startIdx = scrollOffset + 1
    local endIdx = math.min(#options, scrollOffset + maxVisible)

    for i = startIdx, endIdx do
      local opt = options[i]
      local prefix = string.format("%2d. ", i)

      if opt.status then
        local indicator = self:_statusIndicator(opt.status)
        if self._gpu and indicator.fg then
          self:_writeAt(1, y, prefix, COLOR_DIM)
          self:_writeAt(#prefix + 1, y, opt.label)
          self:_writeAt(#prefix + #opt.label + 1, y, indicator.text, indicator.fg)
        else
          self:_writeAt(1, y, prefix .. opt.label .. " " .. indicator.text)
        end
      else
        self:_writeAt(1, y, prefix .. opt.label)
      end
      y = y + 1
    end

    -- Scroll indicator
    if #options > maxVisible then
      if scrollOffset > 0 then
        self:_writeLine(self._height - 2, "  ▲ Scroll up", COLOR_DIM)
      end
      if endIdx < #options then
        self:_writeLine(self._height - 1, "  ▼ Scroll down", COLOR_DIM)
      end
    end

    -- Bottom bar
    local barText = "Select option [1-" .. tostring(#options) .. "] or 'q' to quit: "
    if scrollOffset > 0 then
      barText = barText .. " [u]p [d]own"
    end
    self:_separator(self._height - 2)
    return self:_readLine(barText)
  end

  while true do
    local input = redrawMenu()

    if input == "q" or input == "quit" then
      return nil
    end

    -- Scroll commands
    if input == "u" and scrollOffset > 0 then
      scrollOffset = math.max(0, scrollOffset - 1)
      os.sleep(0)
      -- LuaJIT 5.1 compat: no goto — let while loop naturally restart
    end
    if input == "d" then
      local endIdx = math.min(#options, scrollOffset + maxVisible)
      if endIdx < #options then
        scrollOffset = math.min(#options - maxVisible, scrollOffset + 1)
      end
      os.sleep(0)
      -- LuaJIT 5.1 compat: no goto — let while loop naturally restart
    end

    do
      local num = tonumber(input)
      if num and num >= 1 and num <= #options then
        local selected = options[num]
        if selected.action == "exit" then
          return nil
        elseif selected.action == "back" then
          return "back"
        else
          return selected.action
        end
      end
    end

    os.sleep(0)
  end

  return nil
end

-- ===========================================================================
-- First-run wizard
-- ===========================================================================

--- Run the first-run setup wizard.
-- Detects components and guides the user through configuration.
-- Returns the final config or nil if cancelled.
function ConfigUI:runSetupWizard()
  self:_clear()
  self:_drawTitle("AE2-ES Exec Broker Setup Wizard")
  self:_writeLine(3, "Welcome to the AE2 Execution System setup wizard.", COLOR_CYAN)
  self:_writeLine(4, "This wizard will help you configure your Exec Broker.")
  self:_writeLine(5, "")
  self:_writeLine(6, "The wizard will:")
  self:_writeLine(7, "  1. Detect available OC components on your network")
  self:_writeLine(8, "  2. Guide you through selecting each component")
  self:_writeLine(9, "  3. Validate selections and save the configuration")
  self:_writeLine(10, "")
  self:_writeLine(12, "You can exit at any time. Settings are saved at the end.", COLOR_YELLOW)

  if not self:_confirm("Start setup wizard", true) then
    return nil
  end

  -- Step 1: Detect components
  self:_clear()
  self:_drawTitle("Step 1: Detecting Components")
  self:_writeLine(3, "Scanning for OC components...", COLOR_CYAN)
  os.sleep(0.5)

  local detected = self:detectComponents()
  local componentCount = #detected.components
  self:_writeLine(5, string.format("Found %d components.", componentCount))

  if componentCount == 0 then
    self:_writeLine(7, "No OC components detected. Make sure:", COLOR_RED)
    self:_writeLine(8, "  - The computer has a component bus")
    self:_writeLine(9, "  - Blocks are placed adjacent to the computer")
    self:_writeLine(10, "  - Adaptors are connected to GT machines")
    self:_writeLine(12, "You can still configure manually.", COLOR_YELLOW)
  else
    self:_writeLine(6, "")
    local y = 7
    if detected.modem then
      self:_writeLine(y, string.format("  Modem: %s", detected.modem.address), COLOR_GREEN)
      y = y + 1
    end
    if detected.transposer then
      self:_writeLine(y, string.format("  Transposer: %s", detected.transposer.address), COLOR_GREEN)
      y = y + 1
    end
    if detected.redstone then
      self:_writeLine(y, string.format("  Redstone I/O: %s", detected.redstone.address), COLOR_GREEN)
      y = y + 1
    end
    if detected.meController then
      self:_writeLine(y, string.format("  ME Controller: %s", detected.meController.address), COLOR_GREEN)
      y = y + 1
    end
    if #detected.meInterfaces > 0 then
      self:_writeLine(y, string.format("  ME Interfaces: %d found", #detected.meInterfaces), COLOR_CYAN)
      y = y + 1
    end
    if #detected.gtMachines > 0 then
      self:_writeLine(y, string.format("  GT Machines: %d found", #detected.gtMachines), COLOR_CYAN)
      y = y + 1
    end
  end

  self:_pressAnyKey()

  -- Step 2: Broker ID
  self:_clear()
  self:_drawTitle("Step 2: Broker Identity")
  self:_writeLine(3, "Enter a friendly name for this broker.", COLOR_CYAN)
  self:_writeLine(4, "This name appears in the Supervisor dashboard.")
  self:_writeLine(5, "Example: 'EB-Ore-Processing', 'EB-Macerator-Row1'", COLOR_GRAY)

  local brokerId = self:_readLine("Broker ID: ", "broker-1")
  self:_ensureConfig()
  self._config.brokerId = brokerId

  -- Step 3: Modem configuration
  self:_clear()
  self:_drawTitle("Step 3: Modem Configuration")
  self:_writeLine(3, "The broker uses a modem to broadcast telemetry to the Supervisor.", COLOR_CYAN)
  self:_writeLine(4, "This is optional but recommended for supervision.")

  local modemAddr = self:_selectComponent("modem", detected.modem, "Select modem (or leave blank to skip)")
  self._config.modemAddress = modemAddr

  if modemAddr and modemAddr ~= "" then
    local port = self:_readNumber("Telemetry broadcast port", 123, 1, 65535)
    self._config.telemetryPort = port
  end

  -- Step 4: Redstone I/O
  self:_clear()
  self:_drawTitle("Step 4: Redstone I/O Block")
  self:_writeLine(3, "Optional: Redstone I/O block for main-net/subnet gatekeeping.", COLOR_CYAN)

  local rsAddr = self:_selectComponent("redstone", detected.redstone, "Select redstone block (or skip)")
  self._config.redstoneAddress = rsAddr

  if rsAddr and rsAddr ~= "" then
    self:_writeLine(5, "")
    self:_writeLine(6, "Sides: 0=bottom, 1=top, 2=back, 3=front, 4=left, 5=right", COLOR_DIM)
    local rsSide = self:_readNumber("Redstone lock output side", 5, 0, 5)
    self._config.redstoneSide = rsSide
  end

  -- Step 5: ME Controller (Central Buffer)
  self:_clear()
  self:_drawTitle("Step 5: ME Controller (Central Buffer)")
  self:_writeLine(3, "The ME Controller provides direct access to the AE2 network.", COLOR_CYAN)
  self:_writeLine(4, "Items and fluids are queried via getItemsInNetwork().")
  self:_writeLine(5, "Replaces the old inventory controller + tank controller approach.")
  if detected.meController then
    self:_writeLine(7, string.format("Detected: %s", detected.meController.address), COLOR_GREEN)
  end
  self:_writeLine(9, "")

  local meAddr = self:_readLine("ME Controller address (or skip): ", detected.meController and detected.meController.address or "")
  self._config.meControllerAddr = meAddr

  -- Step 6: Database
  self:_clear()
  self:_drawTitle("Step 6: Database")
  self:_writeLine(3, "The OC database stores item stack information.", COLOR_CYAN)
  self:_writeLine(4, "The broker stores items to / reads from this database")
  self:_writeLine(5, "and sets them into each lane's dual interface.")
  self:_writeLine(6, "")
  self:_writeLine(7, "Required — the broker cannot transfer items without it.", COLOR_YELLOW)
  if detected.database then
    self:_writeLine(9, string.format("Detected: %s", detected.database.address), COLOR_GREEN)
  end
  self:_writeLine(10, "")

  local dbAddr = self:_readLine("Database address: ", detected.database and detected.database.address or "")
  self._config.databaseAddr = dbAddr

  -- Step 7: Lane configuration
  self:_clear()
  self:_drawTitle("Step 7: Lane Configuration")
  self:_writeLine(3, "Configure each processing lane that this broker manages.", COLOR_CYAN)
  self:_writeLine(4, "Each lane contains an adapter, dual interface, transposer, and machine.")
  self:_writeLine(5, "Lanes are numbered sequentially (Lane 1, Lane 2, ...).")
  self:_writeLine(6, "")

  self._config.machines = {}
  self._config.machineTransposers = {}

  local laneCount = self:_readNumber("How many lanes to configure", 1, 1, 16)

  for i = 1, laneCount do
    local laneId = "Lane " .. tostring(i)
    self:_setupTransposerSides(laneId)
    local cfg = self._config.machineTransposers[laneId]
    if cfg and cfg.machineAddr and cfg.machineAddr ~= "" then
      table.insert(self._config.machines, {
        laneId = laneId,
        machineAddr = cfg.machineAddr,
      })
      self:_setupMachineType(cfg.machineAddr)
    end
  end

  -- Step 7: Timing
  self:_clear()
  self:_drawTitle("Step 7: Timing Configuration")
  self:_writeLine(3, "Configure polling and timing parameters:", COLOR_CYAN)

  self._config.pollInterval = self:_readNumber("Poll interval (seconds)", 0.5, 0.05, 60)
  self._config.heartbeatInterval = self:_readNumber("Heartbeat interval (seconds)", 2.0, 0.1, 300)
  self._config.debounceWindow = self:_readNumber("Buffer debounce window (seconds)", 1.5, 0.1, 30)
  self._config.queueSize = self:_readNumber("Job queue max size", 64, 1, 1000)

  -- Step 9: Summary & save
  self:_clear()
  self:_drawTitle("Step 9: Summary & Save")
  self:_showConfigSummary()

  if self:_confirm("Save this configuration", true) then
    local ok, err = self:saveConfig()
    if ok then
      self:_showMessage("Configuration saved successfully!\n\nBroker '" .. brokerId .. "' is ready.\nRestart the broker to apply changes.")
      return self._config
    else
      self:_showMessage("Failed to save config: " .. tostring(err))
      if self:_confirm("Try again", true) then
        return self:runSetupWizard()
      end
      return nil
    end
  else
    if self:_confirm("Discard this configuration", false) then
      return nil
    end
    return self:runSetupWizard()
  end
end

--- Ensure a config table exists (init from defaults if needed).
function ConfigUI:_ensureConfig()
  if not self._config then
    self:resetConfig()
  end
end

--- Select a component from detected list or enter address manually.
-- @param typeName  string  component type label
-- @param detected  table or nil  detected component entry
-- @param prompt    string  display prompt
-- @return string   address or empty string
function ConfigUI:_selectComponent(typeName, detected, prompt)
  local addr = ""
  if detected then
    self:_writeLine(6, string.format("Detected %s: %s", typeName, detected.address), COLOR_GREEN)
    if self:_confirm(string.format("Use this %s", typeName), true) then
      return detected.address
    end
  else
    self:_writeLine(6, string.format("No %s detected.", typeName), COLOR_YELLOW)
  end

  addr = self:_readLine(string.format("%s (or skip): ", prompt))
  return addr
end

--- Configure a lane: dual interface, transposer, machine adapter, and sides.
-- Each lane has:
--   dualInterface  — subnet dual interface (items flow here from central buffer)
--   transposerAddr — item transposer (pulls from subnet, pushes to machine)
--   machineAddr    — GT machine adapter (the actual machine controller)
--   pull/push/return — transposer sides
-- OC adapters are handled natively by the component API — no address needed.
-- @param laneId  string  identifier for this lane (e.g. "Lane 1")
function ConfigUI:_setupTransposerSides(laneId)
  self:_clear()
  self:_drawTitle("Lane Configuration: " .. laneId)
  self:_writeLine(3, "Configure the components for this lane:", COLOR_CYAN)
  self:_writeLine(4, "")
  self:_writeLine(5, "Each lane has:", COLOR_CYAN)
  self:_writeLine(6, "  - Dual Interface    — subnet connection (items arrive here)", COLOR_GRAY)
  self:_writeLine(7, "  - Item Transposer   — moves items into the machine", COLOR_GRAY)
  self:_writeLine(8, "  - Machine Adapter   — the GT machine itself", COLOR_GRAY)
  self:_writeLine(9, "  (OC Adapter is handled natively — no address needed)", COLOR_DIM)
  self:_writeLine(10, "")
  self:_pressAnyKey()

  if not self._config.machineTransposers then
    self._config.machineTransposers = {}
  end

  -- Component addresses
  self:_clear()
  self:_drawTitle(laneId .. " — Component Addresses")
  local dualIface = self:_readLine("Dual Interface address: ", "")
  local transposer = self:_readLine("Item Transposer address: ", "")
  local machine = self:_readLine("Machine Adapter address: ", "")

  -- Transposer sides
  self:_clear()
  self:_drawTitle(laneId .. " — Transposer Sides")
  self:_writeLine(3, "Transposer has three sides:", COLOR_CYAN)
  self:_writeLine(4, "  Pull side   — pulls items FROM the subnet/dual interface", COLOR_GRAY)
  self:_writeLine(5, "  Push side   — drops items INTO the machine input bus", COLOR_GRAY)
  self:_writeLine(6, "  Return side — pulls circuits/output FROM machine back", COLOR_GRAY)
  self:_writeLine(7, "")
  self:_writeLine(8, "Sides: 0=bottom, 1=top, 2=back, 3=front, 4=left, 5=right", COLOR_DIM)
  self:_writeLine(9, "")

  local pullSide = self:_readNumber("PULL side (from subnet)", 2, 0, 5)
  local pushSide = self:_readNumber("PUSH side (into machine input bus)", 3, 0, 5)
  local returnSide = self:_readNumber("RETURN side (from machine output)", 5, 0, 5)

  self._config.machineTransposers[laneId] = {
    dualInterface  = dualIface,
    transposerAddr = transposer,
    machineAddr    = machine,
    pull           = pullSide,
    push           = pushSide,
    return_     = returnSide,
  }
end

--- Prompt user to set machine type and capability profile.
-- @param address  string  machine component address
function ConfigUI:_setupMachineType(address)
  self:_writeLine(0, "", COLOR_GRAY)
  self:_writeLine(0, string.format("  Configuring machine %s", address:sub(1, 16)), COLOR_CYAN)

  local opts = {
    { label = "Basic machine (items + EU)",          action = "basic" },
    { label = "Fluid machine (items + fluids + EU)",  action = "fluid" },
    { label = "Steam machine",                        action = "steam" },
    { label = "Multiblock machine",                   action = "multi" },
  }

  local choice = self:_menuLoop("Machine Type - " .. address:sub(1, 12), opts)
  local profileMap = {
    basic  = 1,
    fluid  = 4,
    steam  = 32,
    multi  = 128,
  }

  if not self._config.machineTypes then self._config.machineTypes = {} end
  self._config.machineTypes[address] = profileMap[choice] or 1
end

--- Show a summary of the current configuration.
function ConfigUI:_showConfigSummary()
  local cfg = self._config
  local y = 3

  self:_writeLine(y, "  Broker ID:          " .. tostring(cfg.brokerId), COLOR_CYAN); y = y + 1
  self:_writeLine(y, "  Modem:              " .. (cfg.modemAddress ~= "" and cfg.modemAddress or "(none)"), self:_statusColor(cfg.modemAddress)); y = y + 1
  self:_writeLine(y, "  Telemetry Port:     " .. tostring(cfg.telemetryPort)); y = y + 1
  self:_writeLine(y, "  Redstone I/O:       " .. (cfg.redstoneAddress ~= "" and cfg.redstoneAddress or "(none)"), self:_statusColor(cfg.redstoneAddress)); y = y + 1
  self:_writeLine(y, "  Redstone Side:     " .. tostring(cfg.redstoneSide or 5)); y = y + 1
  self:_writeLine(y, "  ME Controller:     " .. (cfg.meControllerAddr ~= "" and cfg.meControllerAddr or "(none)"), self:_statusColor(cfg.meControllerAddr)); y = y + 1
  self:_writeLine(y, "  Database:          " .. (cfg.databaseAddr ~= "" and cfg.databaseAddr or "(none)"), self:_statusColor(cfg.databaseAddr)); y = y + 1
  self:_writeLine(y, "  Lanes:              " .. tostring(#(cfg.machines or {})) .. " configured"); y = y + 1
  self:_writeLine(y, "  Poll Interval:      " .. tostring(cfg.pollInterval) .. "s"); y = y + 1
  self:_writeLine(y, "  Heartbeat Interval: " .. tostring(cfg.heartbeatInterval) .. "s"); y = y + 1
  self:_writeLine(y, "  Debounce Window:    " .. tostring(cfg.debounceWindow) .. "s"); y = y + 1
  self:_writeLine(y, "  Queue Size:         " .. tostring(cfg.queueSize)); y = y + 1
  self:_writeLine(y, "  DB Slots:           " .. tostring(cfg.dbSlots or 9)); y = y + 1

  if cfg.machines and #cfg.machines > 0 then
    y = y + 1
    self:_writeLine(y, "  Lane Details:", COLOR_DIM); y = y + 1
    for i, lane in ipairs(cfg.machines) do
      local id = lane.laneId or ("#" .. i)
      local addr = lane.machineAddr or lane.address or "(none)"
      local transposer = ""
      if cfg.machineTransposers and cfg.machineTransposers[id] then
        local t = cfg.machineTransposers[id]
        transposer = string.format(" [pull=%d push=%d ret=%d]", t.pull or 0, t.push or 0, t.return_ or 0)
      end
      self:_writeLine(y, string.format("    %s: %s%s", id, addr:sub(1, 20), transposer), COLOR_GRAY); y = y + 1
    end
  end
end

--- Return color for status text based on whether an address is set.
-- @param addr  string
-- @return number  color constant or nil
function ConfigUI:_statusColor(addr)
  if addr and addr ~= "" then
    return COLOR_GREEN
  end
  return COLOR_YELLOW
end


return ConfigUI
