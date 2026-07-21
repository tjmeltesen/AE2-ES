--[[
hal.lua — HardwareAbstractionLayer (HAL) facade
AE2 Execution System (AE2-ES), Part of Deliverable A: Exec Broker, Module A5

Domain logic lives in five import-safe submodules under src/hal/:
  proxy.lua       — component proxy cache, capability flags, fault codes, constructor
  inventory.lua   — item/fluid transfer operations
  maintenance.lua — maintenance checking, sensor parsing
  me_network.lua  — ME controller, database, interface configuration
  transfer.lua    — transfer utilities, slot checking, redstone, diagnostics

This file is the single import point for backward compatibility.
require("src.hal") returns the same HAL table as before.
]]--

local proxy       = require("src.hal.proxy")
local inventory   = require("src.hal.inventory")
local maintenance = require("src.hal.maintenance")
local me_network  = require("src.hal.me_network")
local transfer    = require("src.hal.transfer")

-- All submodules write methods onto the same HAL table (required from proxy).
-- require("src.hal.proxy") returns the shared HAL table with constructor,
-- capability flags, fault codes, and proxy management methods.
-- The other submodules add their domain methods to this same table.

return proxy
