-- config_ui/connectivity.lua -- connectivity test, import/export, public API
local ConfigUI = require("src.config_ui.menu")

--- Run connectivity tests for all configured components.
function ConfigUI:_runConnectivityTest()
  self:_clear()
  self:_drawTitle("Connectivity Test")
  self:_writeLine(3, "Testing configured components...", COLOR_CYAN)

  local results = {}
  local y = 5

  -- Test modem
  local modemOk, modemMsg = false, "Not configured"
  if self._config.modemAddress and self._config.modemAddress ~= "" then
    modemOk, modemMsg = self:testComponent(self._config.modemAddress, "modem")
  end
  table.insert(results, { name = "Modem", ok = modemOk, msg = modemMsg })
  local indicator = self:_statusIndicator(modemOk and "ok" or "missing")
  self:_writeLine(y, "  Modem:           " .. (modemOk and "OK" or "FAIL") .. " - " .. modemMsg,
    modemOk and COLOR_GREEN or COLOR_RED)
  y = y + 1

  -- Test redstone
  local rsOk, rsMsg = false, "Not configured"
  if self._config.redstoneAddress and self._config.redstoneAddress ~= "" then
    rsOk, rsMsg = self:testComponent(self._config.redstoneAddress)
  end
  table.insert(results, { name = "Redstone", ok = rsOk, msg = rsMsg })
  self:_writeLine(y, "  Redstone I/O:    " .. (rsOk and "OK" or "FAIL") .. " - " .. rsMsg,
    rsOk and COLOR_GREEN or COLOR_RED)
  y = y + 1

  -- Test ME Controller
  local meOk, meMsg = true, "Not configured"
  if self._config.meControllerAddr and self._config.meControllerAddr ~= "" then
    meOk, meMsg = self:testComponent(self._config.meControllerAddr)
  end
  table.insert(results, { name = "ME Controller", ok = meOk, msg = meMsg })
  self:_writeLine(y, "  ME Controller:      " .. (meOk and "OK" or "FAIL") .. " - " .. meMsg,
    meOk and COLOR_GREEN or COLOR_RED)
  y = y + 1

  -- Test each machine
  if self._config.machines and #self._config.machines > 0 then
    y = y + 1
    self:_writeLine(y, "  Machines:", COLOR_DIM)
    y = y + 1
    for _, lane in ipairs(self._config.machines) do
      local addr = lane.machineAddr or lane.address or ""
      local mOk, mMsg = self:testComponent(addr)
      table.insert(results, { name = "Machine " .. lane.laneId, ok = mOk, msg = mMsg })
      self:_writeLine(y, string.format("    %s: %s - %s", lane.laneId or addr:sub(1,8),
        (mOk and "OK" or "FAIL"),
        mMsg:sub(1, 60)),
        mOk and COLOR_GREEN or COLOR_RED)
      y = y + 1
    end
  end

  -- Summary
  y = y + 1
  local passed = 0
  local total = #results
  for _, r in ipairs(results) do
    if r.ok then passed = passed + 1 end
  end
  self:_separator(y)
  y = y + 1
  local summaryColor = (passed == total) and COLOR_GREEN or COLOR_YELLOW
  self:_writeLine(y, string.format("  %d/%d components responding", passed, total), summaryColor)

  self:_pressAnyKey()
end

--- Show connection status for all configured components.
function ConfigUI:_showConnectionStatus()
  self:_clear()
  self:_drawTitle("Connection Status")
  self:_writeLine(3, "Quick status overview (no network test):", COLOR_CYAN)
  local y = 5

  local function showEntry(label, addr)
    local status = (addr and addr ~= "") and "ok" or "unconfigured"
    local ind = self:_statusIndicator(status)
    local display = (addr and addr ~= "") and addr or "(not configured)"
    if self._gpu and ind.fg then
      self:_writeAt(1, y, "  " .. label, COLOR_GRAY)
      self:_writeAt(#label + 4, y, " " .. display)
      self:_writeAt(#label + #display + 5, y, ind.text, ind.fg)
    else
      self:_writeLine(y, "  " .. label .. " " .. display .. " " .. ind.text)
    end
    y = y + 1
  end

  showEntry("Broker ID:", self._config.brokerId)
  showEntry("Modem:", self._config.modemAddress)
  showEntry("Redstone:", self._config.redstoneAddress)
  showEntry("ME Controller:", self._config.meControllerAddr)

  y = y + 1
  local count = #(self._config.machines or {})
  self:_writeLine(y, "  Machines:        " .. tostring(count) .. " configured", (count > 0) and COLOR_GREEN or COLOR_YELLOW)

  if count > 0 then
    y = y + 1
    for _, lane in ipairs(self._config.machines) do
      local addr = lane.machineAddr or lane.address or ""
      local short = addr:sub(1, 36)
      self:_writeLine(y, string.format("    %s: %s", lane.laneId or ("#" .. _), short), COLOR_GRAY)
      y = y + 1
    end
  end

  self:_pressAnyKey()
end

-- ===========================================================================
-- Import/Export
-- ===========================================================================

--- Import configuration from a file.
function ConfigUI:_importConfig()
  local path = self:_readLine("Path to config file [" .. self._configPath .. "]: ", self._configPath)
  if not path or path == "" then
    path = self._configPath
  end

  local prevPath = self._configPath
  self._configPath = path
  local cfg, err = self:loadConfig()
  self._configPath = prevPath

  if cfg then
    self:_showMessage("Configuration loaded from:\n" .. path)
    self._config = cfg
  else
    self:_showMessage("Failed to load: " .. tostring(err))
  end
end

--- Export configuration to the screen (serialized format).
function ConfigUI:_exportConfig()
  self:_clear()
  self:_drawTitle("Exported Configuration")
  self:_writeLine(3, "Config file will be saved to: " .. self._configPath, COLOR_CYAN)
  self:_separator(4)

  if self:_confirm("Export config to " .. self._configPath, true) then
    local ok, err = self:saveConfig()
    if ok then
      self:_showMessage("Configuration exported to:\n" .. self._configPath)
    else
      self:_showMessage("Export failed: " .. tostring(err))
    end
  end
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Get the current config table.
-- @return table or nil
function ConfigUI:getConfig()
  return self._config
end

--- Set the config table directly.
-- @param config  table
function ConfigUI:setConfig(config)
  self._config = config
end

--- Main entry point: detect mode (first-run wizard vs config menu).
-- If config file exists, load and show config menu.
-- If not, run the first-run setup wizard.
-- @return table or nil  final config, or nil if cancelled
function ConfigUI:run()
  if self._logger then self._logger:info("Config UI started") end
  -- Try to load existing config
  local cfg, err = self:loadConfig()

  if cfg then
    self:_clear()
    self:_drawTitle("Configuration Loaded")
    self:_writeLine(3, string.format("Loaded config for broker '%s'", cfg.brokerId or "(unnamed)"), COLOR_GREEN)

    if self:_confirm("Enter configuration menu", true) then
      self:runConfigMenu()
    end
    return self._config
  else
    -- First-run: run setup wizard
    return self:runSetupWizard()
  end
end



return ConfigUI
