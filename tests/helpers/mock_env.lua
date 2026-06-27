-- Mock OC environment for standalone Lua testing
-- Simulates the OpenComputers runtime without needing Minecraft

local MockEnv = {}

-- Mock os.epoch if not available (OC provides this)
if not os.epoch then
  os.epoch = function() return os.time() * 1000 end
end

-- Mock bit32 if not available (Lua 5.2/5.3)
if not bit32 then
  bit32 = {
    bxor = function(a, b)
      local result = 0
      local bit = 1
      while a > 0 or b > 0 do
        local a_bit = a % 2
        local b_bit = b % 2
        if a_bit ~= b_bit then
          result = result + bit
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit = bit * 2
      end
      return result
    end,
    band = function(a, b)
      local result = 0
      local bit = 1
      while a > 0 and b > 0 do
        if a % 2 == 1 and b % 2 == 1 then
          result = result + bit
        end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit = bit * 2
      end
      return result
    end,
  }
end

-- Mock serialization (basic Lua serializer, mirrors OC behavior)
MockEnv.serialization = {
  serialize = function(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then return string.format("%.17g", v)
    elseif t == "string" then return string.format("%q", v)
    elseif t == "table" then
      local out = {}
      table.insert(out, "{")
      local first = true
      for k, val in pairs(v) do
        if not first then table.insert(out, ",") end
        first = false
        local sk = MockEnv.serialization.serialize(k)
        table.insert(out, "[" .. sk .. "]=" .. MockEnv.serialization.serialize(val))
      end
      table.insert(out, "}")
      return table.concat(out)
    end
    return "nil"
  end,
  unserialize = function(s)
    if not s or s == "" then return nil end
    local f, err = load("return " .. s, "unserialize", "t", {})
    if not f then return nil end
    local ok, result = pcall(f)
    if ok then return result end
    return nil
  end,
}

-- Mock OC components
MockEnv.components = {
  modem = {
    sentMessages = {},
    send = function(self, address, port, ...)
      table.insert(self.sentMessages, {address = address, port = port, data = {...}})
      return true
    end,
    broadcast = function(self, port, ...)
      table.insert(self.sentMessages, {address = "BROADCAST", port = port, data = {...}})
      return true
    end,
    clear = function(self)
      self.sentMessages = {}
    end,
  },
  redstone = {
    outputs = {},
    setOutput = function(self, side, value)
      self.outputs[side] = value
    end,
    getInput = function(self, side)
      return self.outputs[side] or 0
    end,
  },
  transposer = {
    transfers = {},
    transferItem = function(self, src, dst, count, srcSlot, dstSlot)
      table.insert(self.transfers, {src = src, dst = dst, count = count, srcSlot = srcSlot, dstSlot = dstSlot})
      return count or 1
    end,
    clear = function(self)
      self.transfers = {}
    end,
  },
}

--- Set up the mock environment
function MockEnv.setup()
  -- Global mocks that modules might expect
  if not component then
    _G.component = {
      list = function() return {} end,
      isAvailable = function() return true end,
      modem = MockEnv.components.modem,
      redstone = MockEnv.components.redstone,
      transposer = MockEnv.components.transposer,
    }
    _G.sides = {
      bottom = 0, top = 1, back = 2, front = 3, right = 4, left = 5,
      down = 0, up = 1, north = 2, south = 3, west = 4, east = 5,
    }
  end
end

return MockEnv
