-- config_ui/terminal.lua -- constructor, I/O detection, rendering, input
local ConfigUI = {}
ConfigUI.__index = ConfigUI

ConfigUI.VERSION = "1.0.0"
ConfigUI.CONFIG_PATH = "/home/ae2es_broker.cfg"

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


return ConfigUI
