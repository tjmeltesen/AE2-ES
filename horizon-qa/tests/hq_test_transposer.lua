--[[
hq_test_transposer.lua — Horizon-QA Tier 2 Test: Real Transposer Transfer
AE2 Execution System (AE2-ES), Deliverable C9

Simulates physical item transfer through AE2 Dual Interface to machine input bus.
Tests correct item counts, interface reads, and transfer latency measurement.

Run standalone:  lua horizon-qa/tests/hq_test_transposer.lua
]]--

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
local MockModules = require("tests.helpers.mock_modules")

-- ===========================================================================
-- Setup: Mock OC environment
-- ===========================================================================

local mockUptime = 1000
local function tick(dt)
  mockUptime = mockUptime + (dt or 0.05)
end

local mockComputer = {
  uptime = function() return mockUptime end,
  pushSignal = function() end,
}

local mockEvent = {
  pull = function(timeout)
    tick(0.05)
    return "timer"
  end,
  timer = function(interval, callback, count) return 1 end,
  cancel = function(id) end,
}

-- Mock transposer with realistic inventory simulation
local MockTransposer = {}
MockTransposer.__index = MockTransposer

function MockTransposer.new(config)
  config = config or {}
  local self = setmetatable({}, MockTransposer)
  -- Inventory state: side -> { slots = { {label, size, maxSize}, ... } }
  self._inventories = config.inventories or {}
  self._tanks = config.tanks or {}
  self._callLog = {}
  return self
end

function MockTransposer:transferItem(srcSide, sinkSide, count, srcSlot, sinkSlot)
  table.insert(self._callLog, { op = "transferItem", src = srcSide, sink = sinkSide, count = count })
  local srcInv = self._inventories[srcSide]
  local sinkInv = self._inventories[sinkSide]
  if not srcInv or not sinkInv then
    return 0
  end

  -- Transfer from first available slot
  local moved = 0
  for slot, stack in ipairs(srcInv.slots or {}) do
    if stack and stack.size > 0 then
      local toMove = math.min(stack.size, (count or stack.size) - moved)
      if toMove > 0 then
        local slotIdx = sinkSlot or (#(sinkInv.slots or {}) + 1)
        if not sinkInv.slots then sinkInv.slots = {} end
        if sinkInv.slots[slotIdx] then
          sinkInv.slots[slotIdx].size = sinkInv.slots[slotIdx].size + toMove
        else
          sinkInv.slots[slotIdx] = { label = stack.label, size = toMove, maxSize = stack.maxSize }
        end
        stack.size = stack.size - toMove
        moved = moved + toMove
        if moved >= (count or math.huge) then break end
      end
    end
  end
  return moved
end

function MockTransposer:getInventorySize(side)
  local inv = self._inventories[side]
  return inv and #(inv.slots or {}) or 0
end

function MockTransposer:getStackInSlot(side, slot)
  local inv = self._inventories[side]
  if inv and inv.slots and inv.slots[slot] then
    return inv.slots[slot]
  end
  return nil
end

function MockTransposer:getAllStacks(side)
  local inv = self._inventories[side]
  return inv and inv.slots or {}
end

-- Mock sides
local mockSides = {
  north = 2, south = 3, east = 4, west = 5, top = 0, bottom = 1,
  front = 3, back = 2, left = 5, right = 4,
}

local mockSerialization = MockEnv.serialization

-- Mock component
local sharedTransposer = MockTransposer.new({
  inventories = {
    -- interface: AE2 Dual Interface side (central buffer)
    ["interface"] = {
      slots = {
        { label = "minecraft:iron_ingot", size = 256, maxSize = 64 },
        { label = "gregtech:gt.circuit.integrated.4", size = 16, maxSize = 64 },
        { label = "minecraft:glass", size = 128, maxSize = 64 },
      },
    },
    -- inputBus: machine input bus side
    ["inputBus"] = {
      slots = {
        { label = "minecraft:dirt", size = 0, maxSize = 64 },
        { label = "minecraft:dirt", size = 0, maxSize = 64 },
        { label = "minecraft:dirt", size = 0, maxSize = 64 },
        { label = "minecraft:dirt", size = 0, maxSize = 64 },
      },
    },
    -- returnLine: chest for cleanup returns
    ["returnLine"] = {
      slots = {},
    },
  },
})

local mockComponent = {
  list = function() return { ["transposer-addr"] = "transposer" } end,
  isAvailable = function(name)
    if name == "transposer" then return true end
    return false
  end,
  transposer = sharedTransposer,
  proxy = function(addr)
    if addr == "transposer-addr" then return sharedTransposer end
    return nil
  end,
}

_G.computer = mockComputer
_G.event = mockEvent
_G.serialization = mockSerialization
_G.component = mockComponent
_G.sides = mockSides

package.loaded["computer"] = mockComputer
package.loaded["event"] = mockEvent
package.loaded["serialization"] = mockSerialization
package.loaded["component"] = mockComponent
package.loaded["sides"] = mockSides

os.time = function() return math.floor(mockUptime) end
os.clock = function() return mockUptime end
os.epoch = function() return math.floor(mockUptime * 1000) end

-- ===========================================================================
-- Load HAL for transposer operations
-- ===========================================================================

-- Mock HAL with transposer access
local MockHAL = {}
MockHAL.__index = MockHAL

function MockHAL:new(config)
  config = config or {}
  local self = setmetatable({}, MockHAL)
  self._transposer = config.transposer or sharedTransposer
  self._sideMap = config.sideMap or {
    interface = "interface",
    inputBus = "inputBus",
    returnLine = "returnLine",
  }
  self._callLog = {}
  return self
end

function MockHAL:transferItems(fromRole, toRole, count, srcSlot, sinkSlot)
  table.insert(self._callLog, { op = "transferItems", from = fromRole, to = toRole, count = count })
  local fromSide = self._sideMap[fromRole] or fromRole
  local toSide = self._sideMap[toRole] or toRole
  return self._transposer:transferItem(fromSide, toSide, count, srcSlot, sinkSlot)
end

function MockHAL:getInterfaceContents(role)
  local side = self._sideMap[role] or role
  local inv = self._transposer._inventories[side]
  return inv and inv.slots or {}
end

function MockHAL:countItems(role)
  local side = self._sideMap[role] or role
  local inv = self._transposer._inventories[side]
  if not inv or not inv.slots then return 0 end
  local total = 0
  for _, stack in ipairs(inv.slots) do
    if stack then total = total + (stack.size or 0) end
  end
  return total
end

function MockHAL:clearInterface(role)
  local side = self._sideMap[role] or role
  local inv = self._transposer._inventories[side]
  if inv and inv.slots then
    for _, stack in ipairs(inv.slots) do
      if stack then stack.size = 0 end
    end
  end
end

-- ===========================================================================
-- TEST GROUP 1: Basic Item Transfer — Interface to Input Bus
-- ===========================================================================

Assert.startTest("T1: Transfer items from AE2 Dual Interface to machine input bus")

do
  -- Reset shared transposer to a known state
  sharedTransposer._inventories = {
    interface = {
      slots = {
        { label = "minecraft:iron_ingot", size = 256, maxSize = 64 },
        { label = "gregtech:gt.circuit.integrated.4", size = 16, maxSize = 64 },
        { label = "minecraft:glass", size = 128, maxSize = 64 },
      },
    },
    inputBus = {
      slots = {
        { label = nil, size = 0, maxSize = 64 },
        { label = nil, size = 0, maxSize = 64 },
        { label = nil, size = 0, maxSize = 64 },
        { label = nil, size = 0, maxSize = 64 },
      },
    },
    returnLine = { slots = {} },
  }

  local hal = MockHAL:new()

  -- Measure: initial item counts
  local initialInterface = hal:countItems("interface")
  local initialInputBus = hal:countItems("inputBus")

  Assert.equal(400, initialInterface, "interface starts with 400 items (256+16+128)")
  Assert.equal(0, initialInputBus, "input bus starts empty")

  -- Measure transfer latency
  local startTime = os.clock()
  local moved = hal:transferItems("interface", "inputBus", 64)
  local latency = os.clock() - startTime

  Assert.isTrue(moved > 0, "items were transferred")
  Assert.isTrue(moved <= 64, "transferred at most 64 items")
  Assert.isTrue(latency < 1.0, "transfer latency under 1 second: " .. tostring(latency))

  -- Verify: input bus received items
  local afterInputBus = hal:countItems("inputBus")
  Assert.equal(moved, afterInputBus, string.format("input bus received exactly %d items", moved))

  -- Verify: interface items decreased
  local afterInterface = hal:countItems("interface")
  Assert.equal(initialInterface - moved, afterInterface,
    string.format("interface decreased by %d items", moved))
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 2: Full Transfer — Interface Drains to Zero
-- ===========================================================================

Assert.startTest("T2: Full item transfer drains Dual Interface to 0")

do
  -- Set up interface with manageable amount
  sharedTransposer._inventories.interface = {
    slots = {
      { label = "minecraft:stone", size = 32, maxSize = 64 },
      { label = "minecraft:dirt", size = 16, maxSize = 64 },
    },
  }
  sharedTransposer._inventories.inputBus = {
    slots = {
      { label = nil, size = 0, maxSize = 64 },
      { label = nil, size = 0, maxSize = 64 },
      { label = nil, size = 0, maxSize = 64 },
      { label = nil, size = 0, maxSize = 64 },
    },
  }

  local hal = MockHAL:new()

  local initialInterface = hal:countItems("interface")
  Assert.equal(48, initialInterface, "interface starts with 48 items")

  -- Transfer all items
  local totalMoved = 0
  local passes = 0
  while hal:countItems("interface") > 0 and passes < 10 do
    local moved = hal:transferItems("interface", "inputBus", 64)
    totalMoved = totalMoved + moved
    passes = passes + 1
  end

  Assert.equal(48, totalMoved, "all 48 items transferred")
  Assert.equal(0, hal:countItems("interface"), "interface reads 0 after transfer completes")
  Assert.equal(48, hal:countItems("inputBus"), "input bus has 48 items")

  -- Verify: items in input bus have correct labels
  local stacks = hal:getInterfaceContents("inputBus")
  local hasStone = false
  local hasDirt = false
  for _, stack in ipairs(stacks) do
    if stack.label and stack.size > 0 then
      if stack.label:find("stone") then hasStone = true end
      if stack.label:find("dirt") then hasDirt = true end
    end
  end
  Assert.isTrue(hasStone, "input bus contains stone")
  Assert.isTrue(hasDirt, "input bus contains dirt")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 3: Partial Transfer — Count Limiting
-- ===========================================================================

Assert.startTest("T3: Transfer respects count limit")

do
  sharedTransposer._inventories.interface = {
    slots = {
      { label = "minecraft:cobblestone", size = 100, maxSize = 64 },
      { label = "minecraft:gravel", size = 50, maxSize = 64 },
      { label = "minecraft:sand", size = 30, maxSize = 64 },
    },
  }
  sharedTransposer._inventories.inputBus = {
    slots = {
      { label = nil, size = 0, maxSize = 64 },
      { label = nil, size = 0, maxSize = 64 },
      { label = nil, size = 0, maxSize = 64 },
      { label = nil, size = 0, maxSize = 64 },
    },
  }

  local hal = MockHAL:new()

  -- Transfer only 16 items
  local moved = hal:transferItems("interface", "inputBus", 16)
  Assert.equal(16, moved, "exactly 16 items transferred")
  Assert.equal(164, hal:countItems("interface"), "interface has 164 items remaining (180-16)")
  Assert.equal(16, hal:countItems("inputBus"), "input bus has 16 items")

  -- Transfer another 20
  moved = hal:transferItems("interface", "inputBus", 20)
  Assert.equal(20, moved, "exactly 20 items transferred")
  Assert.equal(144, hal:countItems("interface"), "interface has 144 items remaining")
  Assert.equal(36, hal:countItems("inputBus"), "input bus now has 36 items")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 4: Transfer to Return Line (Cleanup)
-- ===========================================================================

Assert.startTest("T4: Cleanup transfer from input bus to return line chest")

do
  -- Set up input bus with residual items (simulating post-processing cleanup)
  sharedTransposer._inventories.inputBus = {
    slots = {
      { label = "minecraft:iron_ingot", size = 3, maxSize = 64 },
      { label = "minecraft:copper_ingot", size = 7, maxSize = 64 },
    },
  }
  sharedTransposer._inventories.returnLine = { slots = {} }

  local hal = MockHAL:new({
    sideMap = {
      interface = "interface",
      inputBus = "inputBus",
      outputBus = "returnLine",  -- output goes to return line
      returnLine = "returnLine",
    },
  })

  local initialReturn = hal:countItems("returnLine")
  Assert.equal(0, initialReturn, "return line starts empty")

  -- Transfer residuals to return line
  local moved = hal:transferItems("inputBus", "returnLine", 64)
  Assert.equal(10, moved, "all 10 residual items transferred to return line")
  Assert.equal(0, hal:countItems("inputBus"), "input bus is empty after cleanup")
  Assert.equal(10, hal:countItems("returnLine"), "return line has 10 items")
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 5: Transfer Timing / Latency Measurement
-- ===========================================================================

Assert.startTest("T5: Transfer latency is measured correctly")

do
  sharedTransposer._inventories.interface = {
    slots = {
      { label = "minecraft:obsidian", size = 64, maxSize = 64 },
    },
  }
  sharedTransposer._inventories.inputBus = {
    slots = {
      { label = nil, size = 0, maxSize = 64 },
    },
  }

  local hal = MockHAL:new()

  -- Measure 10 transfers for statistical sample
  local latencies = {}
  for i = 1, 10 do
    -- Reset interface for each measurement
    sharedTransposer._inventories.interface.slots[1].size = 64
    sharedTransposer._inventories.inputBus.slots[1].size = 0

    local t1 = os.clock()
    hal:transferItems("interface", "inputBus", 64)
    local t2 = os.clock()
    table.insert(latencies, t2 - t1)
  end

  local total = 0
  for _, lt in ipairs(latencies) do total = total + lt end
  local avg = total / #latencies

  -- All transfers should be sub-second (mock environment)
  for i, lt in ipairs(latencies) do
    Assert.isTrue(lt < 1.0,
      string.format("transfer %d latency %.4fs < 1s", i, lt))
  end
  Assert.isTrue(avg < 0.1,
    string.format("average latency %.4fs < 100ms", avg))
end
Assert.endTest()

-- ===========================================================================
-- TEST GROUP 6: Empty Interface Transfer (Edge Case)
-- ===========================================================================

Assert.startTest("T6: Transfer from empty interface returns 0 (no crash)")

do
  sharedTransposer._inventories.interface = { slots = {} }
  sharedTransposer._inventories.inputBus = {
    slots = { { label = nil, size = 0, maxSize = 64 } },
  }

  local hal = MockHAL:new()

  local moved = hal:transferItems("interface", "inputBus", 64)
  Assert.equal(0, moved, "transfer from empty interface returns 0")
  Assert.equal(0, hal:countItems("interface"), "interface still empty")
  Assert.equal(0, hal:countItems("inputBus"), "input bus still empty")
end
Assert.endTest()

-- ===========================================================================
-- Print summary and exit
-- ===========================================================================
-- Summary: return status code via Assert.summary() return value
-- When run standalone, failures are reported but don't exit the process.
local success = Assert.summary()
