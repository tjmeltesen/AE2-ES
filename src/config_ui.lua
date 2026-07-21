--[[
config_ui.lua — Exec Broker interactive configuration UI (facade)
AE2 Execution System (AE2-ES)

Domain logic lives in seven submodules under src/config_ui/:
  terminal.lua     — constructor, I/O detection, rendering, input
  detect.lua       — component detection
  persist.lua      — load/save/reset config
  build.lua        — buildExecConfig
  wizard.lua       — setup wizard + menu loop
  menu.lua         — config menu + field editors
  connectivity.lua — connectivity test, import/export, public API

Each submodule extends the same ConfigUI table via a require chain.
require("src.config_ui") returns the fully built ConfigUI table.
]]--

return require("src.config_ui.connectivity")
