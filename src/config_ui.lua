--[[
config_ui.lua — Interactive Configuration UI for Exec Broker (A13)
AE2 Execution System (AE2-ES)
Part of Deliverable A: Exec Broker

Interactive terminal-based setup wizard and runtime configuration manager
for the Exec Broker. Users can detect OC components, configure all 14+
parameters, test connectivity, and persist config without editing Lua files.

Integration:
  exec_broker.lua checks for saved config on startup /home/ae2es_broker.cfg,
  falls back to wizard if missing.

Graceful fallback: if GPU/screen not available, uses basic terminal I/O.
Cooperative multitasking: yields between screens via os.sleep(0).
]]--

-- DEBUG: Wrap io.write to catch table args
local _orig_write = io.write
io.write = function(...)
  local args = {...}
  for i, v in ipairs(args) do
    if type(v) == "table" then
      print("DEBUG io.write got TABLE at arg " .. i .. ": " .. tostring(v))
      args[i] = tostring(v)
    end
  end
  return _orig_write(table.unpack(args))
end

local ConfigUI = {}
ConfigUI.__index = ConfigUI

-- ===========================================================================
-- Constants
-- ===========================================================================

ConfigUI.VERSION = "1.0.0"
ConfigUI.CONFIG_PATH = "/home/ae2es_broker.cfg"

-- Default configuration template
local DEFAULT_CONFIG = {
  brokerId          = "",
  modemAddress      = "",
  telemetryPort     = 123,
  machines          = {},
  machineTypes      = {},
  redstoneAddress   = "",
  redstoneSide      = 5,
  meControllerAddr = "",  -- ME Controller (central buffer; replaces item/fluid adapters)
  databaseAddr    = "",    -- OC database (stores item stack data for transfer)
  -- Per-lane transposer config (set during machine config)
  -- { [laneName] = { dualInterface, transposerAddr, machineAddr, pull, push, return } }
  machineTransposers = {},
  pollInterval      = 0.5,
  heartbeatInterval = 2.0,
  debounceWindow    = 1.5,
  queueSize         = 64,
  dbSlots           = 9,     -- OC Database slot count (1-9 standard, up to 16 with upgrades)
}

-- Capability profile labels for display
local CAP_PROFILES = {
  [1]  = "Basic (items + EU)",
  [4]  = "Items + Fluids + EU",
  [32] = "Steam powered",
  [128] = "Multiblock (items + fluids + EU + maint.)",
}

-- Status colors (used for color-coded indicators)
local COLOR_GREEN  = 0x00FF00
local COLOR_RED    = 0xFF0000
local COLOR_YELLOW = 0xFFFF00
local COLOR_CYAN   = 0x00FFFF
local COLOR_WHITE  = 0xFFFFFF
local COLOR_GRAY   = 0x888888
local COLOR_DIM    = 0x444444

-- ===========================================================================
-- Safe module loader
-- ===========================================================================

local function safeRequire(name)
  local ok, mod = pcall(require, name)
  if ok then return mod end
  return nil
end

-- ===========================================================================
-- Constructor
-- ===========================================================================

--- Create a new ConfigUI instance.
-- @param configPath  string  optional path for config file (default /home/ae2es_broker.cfg)
-- @param options     table   optional overrides:
--   gpu        — GPU component (for testing injection)
--   screen     — screen component (for testing injection)
--   termLib    — term library (for testing injection)
--   filesystem — filesystem for config persistence (for testing)
--   component  — component library (for testing injection)
-- @return ConfigUI instance
function ConfigUI.new(configPath, options)
  options = options or {}
  local self = setmetatable({
    _configPath   = configPath or ConfigUI.CONFIG_PATH,
    _config       = nil,
    _screenMode   = nil,   -- "gpu", "terminal", or nil
    _gpu          = nil,
    _screen       = nil,
    _term         = nil,
    _filesystem   = options.filesystem,
    _component    = options.component,
    _termFallback = nil,
    _width        = 80,
    _height       = 25,

    -- For testing: injected modules
    _mockGPU      = options.gpu,
    _mockScreen   = options.screen,
    _mockTerm     = options.termLib,

    -- Machine detection state cache
    _detectedComponents = nil,

    -- Running flag
      _running      = true,
      _logger       = nil,
  }, ConfigUI)

  -- Detect I/O mode
  self:_detectIO()

  -- Initialize logger if available
  local ok, BrokerLogger = pcall(require, "src.broker_logger")
  if ok and BrokerLogger and BrokerLogger.new then
    self._logger = BrokerLogger.new("config_ui")
  end

  return self
end

-- ===========================================================================
-- I/O detection
-- ===========================================================================

--- Detect available I/O system: GPU+screen, or basic terminal fallback.
function ConfigUI:_detectIO()
  -- Try injected mock first (for testing)
  if self._mockGPU and self._mockScreen then
    self._gpu = self._mockGPU
    self._screen = self._mockScreen
    self._term = self._mockTerm
    self._screenMode = "gpu"
    if type(self._gpu.getResolution) == "function" then
      local w, h = self._gpu:getResolution()
      if type(w) == "number" and type(h) == "number" then
        self._width, self._height = w, h
      end
    end
    return
  end

  -- Try real OC GPU + screen
  local component = self._component or safeRequire("component")
  local gpu
  if component and component.isAvailable and component.isAvailable("gpu") then
    gpu = component.gpu
  end

  if gpu and gpu.getResolution then
    local ok, w, h = pcall(gpu.getResolution, gpu)
    if ok and type(w) == "number" and type(h) == "number" then
      self._gpu = gpu
      self._screen = component.screen
      self._term = safeRequire("term")
      -- Bind term to GPU for proper OC rendering
      if self._term and self._term.bind and self._screen then
        pcall(self._term.bind, self._gpu, self._screen)
      end
      self._screenMode = "gpu"
      self._width, self._height = w, h
      return
    end
  end

  -- Fallback: basic terminal
  self._screenMode = "terminal"
  self._width = 80
  self._height = 25
end

--- Check if running in GPU mode (vs basic terminal).
-- @return boolean
function ConfigUI:hasGPU()
  return self._screenMode == "gpu"
end

-- ===========================================================================
-- Screen I/O primitives
-- ===========================================================================

--- Clear the screen.
function ConfigUI:_clear()
  -- Always print some newlines for terminal fallback
  print("\n\n\n")
  -- Try GPU term clear
  if self._term then
    pcall(self._term.clear)
    if self._term.setCursor then
      pcall(self._term.setCursor, 1, 1)
    end
  end
end

--- Set foreground color (GPU mode only).
-- @param color  number  RGB hex value
function ConfigUI:_setFG(color)
  if self._gpu and self._gpu.setForeground then
    pcall(self._gpu.setForeground, self._gpu, color)
  end
end

--- Set background color (GPU mode only).
-- @param color  number  RGB hex value
function ConfigUI:_setBG(color)
  if self._gpu and self._gpu.setBackground then
    pcall(self._gpu.setBackground, self._gpu, color)
  end
end

--- Reset colors to defaults.
function ConfigUI:_resetColor()
  if self._gpu then
    if self._gpu.setForeground then
      pcall(self._gpu.setForeground, self._gpu, COLOR_WHITE)
    end
    if self._gpu.setBackground then
      pcall(self._gpu.setBackground, self._gpu, 0x000000)
    end
  end
end

--- Write text at a specific position (GPU mode) or to stdout (terminal mode).
-- @param x      number  column (1-based)
-- @param y      number  row (1-based)
-- @param text   string  text to display
-- @param fg     number  optional foreground color
-- @param bg     number  optional background color
function ConfigUI:_writeAt(x, y, text, fg, bg)
  -- Guard against non-string values (OC io.write rejects tables/nil)
  local s = tostring(text or "")
  print(s)
  -- Then try GPU rendering
  if self._gpu and self._gpu.set then
    if fg then self:_setFG(fg) end
    if bg then self:_setBG(bg) end
    pcall(self._gpu.set, self._gpu, x, y, s)
    self:_resetColor()
  end
end

--- Write a line of text at row y.
-- @param y     number
-- @param text  string
-- @param fg    optional foreground color
function ConfigUI:_writeLine(y, text, fg)
  self:_writeAt(1, y, text, fg)
end

--- Draw a horizontal separator line.
-- @param y  number  row
-- @param ch string  separator character (default "─")
function ConfigUI:_separator(y, ch)
  ch = ch or "─"
  local line = string.rep(ch, self._width)
  self:_writeLine(y, line, COLOR_DIM)
end

--- Draw a title bar across the top of the screen.
-- @param title  string
function ConfigUI:_drawTitle(title)
  if self._gpu then
    self:_setBG(0x003366)
    self:_setFG(COLOR_WHITE)
    local padded = " " .. title .. " "
    local padLen = math.max(0, self._width - #padded)
    local leftPad = math.floor(padLen / 2)
    pcall(self._gpu.set, self._gpu, 1, 1, string.rep(" ", self._width))
    pcall(self._gpu.set, self._gpu, leftPad + 1, 1, padded)
    self:_resetColor()
  else
    print("")
    print("=== " .. title .. " ===")
    print("")
  end
end

--- Draw a status indicator.
-- @param status  string  "ok", "missing", "unconfigured", or custom label
-- @return string  colored indicator text
function ConfigUI:_statusIndicator(status)
  if status == "ok" or status == "connected" then
    if self._gpu then
      return { text = " [OK]", fg = COLOR_GREEN }
    end
    return { text = " [OK]", plain = "[OK]" }
  elseif status == "missing" or status == "error" then
    if self._gpu then
      return { text = " [MISSING]", fg = COLOR_RED }
    end
    return { text = " [MISSING]", plain = "[MISSING]" }
  elseif status == "unconfigured" then
    if self._gpu then
      return { text = " [--]", fg = COLOR_YELLOW }
    end
    return { text = " [--]", plain = "[--]" }
  else
    if self._gpu then
      return { text = " [" .. status .. "]", fg = COLOR_CYAN }
    end
    return { text = " [" .. status .. "]", plain = "[" .. status .. "]" }
  end
end

-- ===========================================================================
-- Input primitives
-- ===========================================================================

--- Read a line of input from the user.
-- @param prompt  string  optional prompt text
-- @param default string  optional default value
-- @return string  user input (or default if empty)
function ConfigUI:_readLine(prompt, default)
  -- Uses io.read() — simpler and more reliable on OC than term key events
  if prompt then io.write(tostring(prompt)) end
  io.flush()
  local input = io.read()
  if input and #input > 0 then
    return input
  end
  return default or ""
end

--- Read a numeric value from the user.
-- @param prompt  string
-- @param default number
-- @param min     number  optional minimum
-- @param max     number  optional maximum
-- @return number
function ConfigUI:_readNumber(prompt, default, min, max)
  while true do
    local input = self:_readLine(prompt .. " [" .. tostring(default) .. "]: ")
    if input == "" then return default end
    local num = tonumber(input)
    if num then
      if (min == nil or num >= min) and (max == nil or num <= max) then
        return num
      end
      self:_writeLine(0, "Value must be between " .. tostring(min) .. " and " .. tostring(max), COLOR_RED)
    else
      self:_writeLine(0, "Invalid number. Try again.", COLOR_RED)
    end
    os.sleep(0)
  end
end

--- Read a yes/no confirmation.
-- @param prompt  string
-- @param default boolean  optional default (true = "Y/n", false = "y/N")
-- @return boolean
function ConfigUI:_confirm(prompt, default)
  local suffix
  if default == nil then
    suffix = " (y/n)"
  elseif default then
    suffix = " (Y/n)"
  else
    suffix = " (y/N)"
  end
  local input = self:_readLine(prompt .. suffix .. ": ")
  if input == "" and default ~= nil then return default end
  local lc = input:lower()
  return lc == "y" or lc == "yes"
end

--- Wait for a key press then return.
function ConfigUI:_pressAnyKey()
  io.write("Press Enter to continue...")
  io.flush()
  io.read()
end

--- Show a centered message and wait for confirmation.
-- @param message  string
function ConfigUI:_showMessage(message)
  self:_clear()
  self:_drawTitle("Message")
  local lines = {}
  for line in message:gmatch("[^\n]+") do
    table.insert(lines, line)
  end
  local startY = math.floor((self._height - #lines) / 2)
  for i, line in ipairs(lines) do
    local x = math.floor((self._width - #line) / 2)
    self:_writeAt(math.max(1, x), startY + i, line, COLOR_CYAN)
  end
  self:_pressAnyKey()
end

-- ===========================================================================
-- Component detection
-- ===========================================================================

--- Detect available OC components on the system.
-- Scans for modem, transposer, redstone, adapters, ME controllers,
-- ME interfaces, and other known component types.
-- @return table { components = {...}, errors = {...} }
function ConfigUI:detectComponents()
  if self._detectedComponents then
    return self._detectedComponents
  end

  local component = self._component or safeRequire("component")
  local result = {
    components = {},
    errors = {},
    modem = nil,
    transposer = nil,
    redstone = nil,
    database = nil,
    meController = nil,
    meInterfaces = {},
    gtMachines = {},
    misc = {},
  }

  if not component then
    table.insert(result.errors, "OC component library not available")
    self._detectedComponents = result
    return result
  end

  -- Enumerate all components
  local ok, iter = pcall(component.list)
  if not ok then
    table.insert(result.errors, "component.list() failed")
    self._detectedComponents = result
    return result
  end

  for address, name in iter do
    local entry = { address = address, type = name }
    table.insert(result.components, entry)

    if name == "modem" then
      result.modem = entry
    elseif name == "transposer" then
      result.transposer = entry
    elseif name == "redstone" then
      result.redstone = entry
    elseif name == "database" then
      result.database = entry
    elseif name == "me_controller" then
      result.meController = entry
    elseif name == "me_interface" then
      table.insert(result.meInterfaces, entry)
    elseif name:find("gt_machine") or name:find("^gt_") then
      table.insert(result.gtMachines, entry)
    else
      table.insert(result.misc, entry)
    end
  end

  -- Sort machines and interfaces by address for deterministic order
  local function sortByAddr(a, b)
    return a.address < b.address
  end
  table.sort(result.gtMachines, sortByAddr)
  table.sort(result.meInterfaces, sortByAddr)

  self._detectedComponents = result
  return result
end

--- Detect a specific component by type.
-- @param typeName  string  e.g. "modem", "transposer"
-- @return table or nil  { address, type }
function ConfigUI:findComponent(typeName)
  local detected = self:detectComponents()
  for _, entry in ipairs(detected.components) do
    if entry.type == typeName then
      return entry
    end
  end
  return nil
end

--- Test connectivity to a component address.
-- Attempts to create a proxy and query basic info.
-- @param address  string  component address
-- @param compType string  optional expected type
-- @return boolean, string  success, diagnostic message
function ConfigUI:testComponent(address, compType)
  if not address or address == "" then
    return false, "No address provided"
  end

  local component = self._component or safeRequire("component")
  if not component then
    return false, "OC component library not available"
  end

  local ok, proxy = pcall(component.proxy, address)
  if not ok or not proxy then
    return false, "component.proxy() failed for this address. Check that the address is correct and the block is still placed."
  end

  -- Try to get basic type info
  local proxyType = ""
  local typeOk, typeVal = pcall(function() return proxy.type end)
  if typeOk and typeVal then
    proxyType = tostring(typeVal)
  end

  local addrOk, addrVal = pcall(function() return proxy.address end)
  local proxyAddr = ""
  if addrOk and addrVal then
    proxyAddr = tostring(addrVal)
  end

  if compType and proxyType ~= compType then
    return false, string.format("Expected type '%s' but proxy reports type '%s'", compType, proxyType)
  end

  -- Additional validation by type
  if compType == "modem" or proxyType == "modem" then
    local openOk, _ = pcall(function() return proxy.open(math.random(60000, 65535)) end)
    if not openOk then
      return false, "Modem proxy exists but open() failed. Check that the modem is installed and the computer has a network card."
    end
    pcall(function() return proxy.close(123) end)
    return true, "Modem connected and responding"
  end

  if proxyAddr and #proxyAddr > 0 then
    return true, string.format("Proxy created: type=%s, address=%s", proxyType, proxyAddr)
  end

  return true, "Proxy created successfully"
end

-- ===========================================================================
-- Config persistence
-- ===========================================================================

--- Load config from the filesystem.
-- @return table or nil  config, or nil if file doesn't exist/corrupt
function ConfigUI:loadConfig()
  local fs = self._filesystem or safeRequire("filesystem")
  if not fs then
    return nil, "Filesystem library not available"
  end

  local path = self._configPath
  local exists
  local existsOk, existsVal = pcall(fs.exists, path)
  if existsOk then
    exists = existsVal
  else
    exists = false
  end

  if not exists then
    return nil, "Config file not found"
  end

  local ok, fh = pcall(io.open, path, "r")
  if not ok or not fh then
    return nil, "Could not open config file for reading"
  end

  local content = fh:read("*a")
  fh:close()

  if not content or #content == 0 then
    return nil, "Config file is empty"
  end

  -- Try to load as serialized Lua table
  local loadOk, chunk = pcall(load, content)
  if not loadOk then
    return nil, "Config file contains invalid Lua syntax: " .. tostring(chunk)
  end

  local execOk, config = pcall(chunk)
  if not execOk or type(config) ~= "table" then
    return nil, "Config file contains invalid Lua data"
  end

  -- Validate basic structure
  if type(config.version) ~= "string" then
    config.version = ConfigUI.VERSION
  end

  self._config = config
  return config, nil
end


-- ===========================================================================
-- Safe date helper (os.date returns a table in OC, a string in standard Lua)
-- ===========================================================================
local function _safeDate()
  local d = os.date()
  if type(d) == "table" then
    -- OC returns a broken-down time table; format it manually
    return string.format("%04d-%02d-%02d %02d:%02d:%02d",
      d.year or 0, d.month or 0, d.day or 0,
      d.hour or 0, d.min  or 0, d.sec  or 0)
  end
  return tostring(d)
end
--- Save config to the filesystem.
-- @param config  table  configuration to persist
-- @return boolean, string  success, error message
function ConfigUI:saveConfig(config)
  config = config or self._config
  if not config then
    return false, "No config to save"
  end

  -- Add version marker
  config.version = ConfigUI.VERSION
  config._savedAt = os.time()

  -- Serialize to Lua table format
  local ok, serialized = pcall(self._serializeTable, self, config, "")
  if not ok then
    return false, "Serialization failed: " .. tostring(serialized)
  end
  if type(serialized) ~= "string" then
    return false, "Serialization returned a non-string: " .. type(serialized)
  end

  local path = tostring(self._configPath)   -- guard: must be a string for io.open
  local fh, openErr = io.open(path, "w")
  if not fh then
    return false, "Could not open config file for writing (" .. path .. "): " .. tostring(openErr)
  end

  -- os.date() returns a table in OC — use _safeDate() instead of os.date()
  local header = table.concat({
    "return {\n",
    "  -- AE2-ES Exec Broker Config\n",
    "  -- Generated by config_ui.lua v", tostring(ConfigUI.VERSION), "\n",
    "  -- Saved: ", _safeDate(), "\n\n",
  })

  -- Remove outer braces from serialized table since we already wrote "return {"
  local body = serialized
  if body:sub(1, 1) == "{" then
    body = body:sub(2, #body - 1)
    body = body:gsub("^\n", "")
  end

  -- Write strings explicitly — OC io/buffer rejects non-string arguments
  fh:write(tostring(header))
  fh:write(tostring(body))
  fh:write("\n}\n")
  fh:close()

  self._config = config
  print("Config saved to " .. path)
  return true, nil
end
--- Recursively serialize a Lua table to a compact Lua string.
-- @param t     table
-- @param indent  string  current indentation
-- @param top     boolean  top-level call
-- @return string
function ConfigUI:_serializeTable(t, indent, top)
  indent = indent or ""
  if type(t) ~= "table" then
    return self:_serializeValue(t)
  end

  -- Empty table
  if next(t) == nil then
    return "{}"
  end

  -- Check if array-like
  local isArray = true
  local maxIdx = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k <= 0 or math.floor(k) ~= k then
      isArray = false
    end
    if type(k) == "number" and k > maxIdx then
      maxIdx = k
    end
  end

  local parts = {}
  local count = 0

  if isArray then
    -- Array-style serialization
    table.insert(parts, "{\n")
    for i = 1, maxIdx do
      if t[i] ~= nil then
        local val = self:_serializeValue(t[i])
        table.insert(parts, indent .. "  " .. val .. ",\n")
        count = count + 1
      end
    end
    table.insert(parts, indent .. "}")
  else
    -- Map-style serialization
    local keys = {}
    for k, _ in pairs(t) do
      table.insert(keys, k)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    table.insert(parts, "{\n")
    for _, k in ipairs(keys) do
      local val = t[k]
      local keyStr
      if type(k) == "string" then
        local reserved = {
          ["and"]=true,["break"]=true,["do"]=true,["else"]=true,
          ["elseif"]=true,["end"]=true,["false"]=true,["for"]=true,
          ["function"]=true,["if"]=true,["in"]=true,["local"]=true,
          ["nil"]=true,["not"]=true,["or"]=true,["repeat"]=true,
          ["return"]=true,["then"]=true,["true"]=true,["until"]=true,
          ["while"]=true,
        }
        if k:match("^[%a_][%w_]*$") and not reserved[k] then
          keyStr = k
        else
          keyStr = "[\"" .. k:gsub("\"", "\\\"") .. "\"]"
        end
      else
        keyStr = "[" .. tostring(k) .. "]"
      end

      if type(val) == "table" then
        local child = self:_serializeTable(val, indent .. "  ")
        table.insert(parts, indent .. "  " .. keyStr .. " = " .. child .. ",\n")
      else
        local valStr = self:_serializeValue(val)
        table.insert(parts, indent .. "  " .. keyStr .. " = " .. valStr .. ",\n")
      end
    end
    table.insert(parts, indent .. "}")
  end

  return table.concat(parts)
end

--- Serialize a single value to Lua literal form.
function ConfigUI:_serializeValue(val)
  local t = type(val)
  if t == "nil" then return "nil" end
  if t == "boolean" then return tostring(val) end
  if t == "number" then
    if val == math.floor(val) and val < 9007199254740992 then
      return tostring(math.floor(val))
    end
    return string.format("%g", val)
  end
  if t == "string" then
    -- Escape control characters and backslashes
    local escaped = val:gsub("\\", "\\\\"):gsub("\"", "\\\""):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    return "\"" .. escaped .. "\""
  end
  -- Tables: recursively serialize; functions/userdata: placeholder
  if t == "table" then return self:_serializeTable(val, "")
  elseif t == "function" then return "\"<function>\""
  elseif t == "userdata" then return "\"<userdata>\""
  else return "\"<" .. t .. ">\""
  end
end

--- Reset config to factory defaults.
-- @return table  fresh default config
function ConfigUI:resetConfig()
  local config = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    if type(v) == "table" then
      config[k] = {}
      for k2, v2 in pairs(v) do
        config[k] = { k2, v2 }
        config[k] = nil
      end
      config[k] = {}
    else
      config[k] = v
    end
  end
  self._config = config
  return config
end

-- ===========================================================================
-- Build config for exec_broker.new()
-- ===========================================================================

--- Convert the stored config to an exec_broker.new()-compatible table.
-- Resolves addresses to component proxies and builds the machines table.
-- @return table  ready for exec_broker.new(config)
function ConfigUI:buildExecConfig()
  local cfg = self._config
  if not cfg then return nil end

  local component = self._component or safeRequire("component")

  -- Build machines table
  local machines = {}
  if cfg.machines then
    for _, lane in ipairs(cfg.machines) do
      local addr = lane.machineAddr or lane.address
      local laneId = lane.laneId or addr
      if addr and addr ~= "" then
        local machineType = (cfg.machineTypes and cfg.machineTypes[laneId]) or "gt_machine"
        local proxy = nil
        if component then
          local ok, p = pcall(component.proxy, addr)
          if ok then proxy = p end
        end

        -- Import MachineNode if available
        local MachineNode
        local ok, mod = pcall(require, "MachineNode")
        if ok then MachineNode = mod end

        if MachineNode then
          machines[addr] = MachineNode.new(addr, {
            machineType = machineType,
            hardwareAddress = addr,
            laneId = laneId,
            interfaceAddress = lane.interfaceAddress
              or (cfg.machineTransposers and cfg.machineTransposers[laneId]
                  and cfg.machineTransposers[laneId].dualInterface)
              or nil,
          })
        else
          -- Stub when MachineNode not available
          machines[addr] = {
            address = addr,
            machineType = machineType,
            _proxy = proxy,
          }
        end
      end
    end
  end

  -- Build modem table
  local modem = nil
  if cfg.modemAddress and cfg.modemAddress ~= "" then
    if component then
      local ok, p = pcall(component.proxy, cfg.modemAddress)
      if ok then modem = p end
    end
  end

  -- Build HAL config
  local halConfig = {}

  local execConfig = {
    brokerId          = cfg.brokerId or "broker-1",
    machines          = machines,
    halConfig         = halConfig,
    queueSize         = cfg.queueSize or 64,
    modem             = modem,
    telemetryPort     = cfg.telemetryPort or 123,
    pollInterval      = cfg.pollInterval or 0.5,
    heartbeatInterval = cfg.heartbeatInterval or 2.0,
    debounceWindow    = cfg.debounceWindow or 1.5,
    dbSlots           = cfg.dbSlots or 9,
  }

  -- ME Controller and database addresses (expected by exec_broker)
  execConfig.meControllerAddr = cfg.meControllerAddr or ''
  execConfig.databaseAddr = cfg.databaseAddr or ''
  execConfig.redstoneAddress = cfg.redstoneAddress or ''
  execConfig.redstoneSide = cfg.redstoneSide or 5

  -- Build bufferFeeder closure: single HAL call to ME Controller
  -- (replaces old inventory_controller + tank_controller dual-adapter approach)
  local bufferFeeder = nil
  local meAddr = execConfig.meControllerAddr
  if meAddr and meAddr ~= '' then
    local HAL = self._hal  -- capture for use inside closure
    bufferFeeder = function()
      return HAL:getMEContents(meAddr)
    end
  end
  execConfig.bufferFeeder = bufferFeeder

  return execConfig
end

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
