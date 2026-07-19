-- Every reusable src/ and lib/ module must load without OpenComputers APIs.
-- Runtime APIs are resolved lazily by the operations that need them.

local modules = {
  "src.BufferSnapshot",
  "src.MachineNode",
  "src.broker_logger",
  "src.config_ui",
  "src.exec_broker",
  "src.global_logger",
  "src.hal",
  "src.job_queue",
  "src.jobmanifest",
  "src.log_entry",
  "src.log_exporter",
  "src.log_filter",
  "src.log_ring_buffer",
  "src.maintenance_report",
  "src.profiler",
  "src.supervisor",
  "src.telemetrypayload",
  "src.timeslicescheduler",
  "src.ui.common",
  "lib.bounded_list",
  "lib.component_discover",
  "lib.persistence",
  "lib.program_framework",
  "lib.state_machine",
}

local ocModules = { "component", "computer", "event", "filesystem", "sides", "term" }
local savedGlobals = {}
for _, name in ipairs(ocModules) do
  savedGlobals[name] = rawget(_G, name)
  _G[name] = nil
  package.loaded[name] = nil
end

for _, name in ipairs(modules) do
  package.loaded[name] = nil
end

for _, name in ipairs(modules) do
  local ok, result = pcall(require, name)
  assert(ok, "module must be import-safe: " .. name .. ": " .. tostring(result))
end

for _, name in ipairs(ocModules) do
  _G[name] = savedGlobals[name]
end

return true
