-- scheduler_registry.lua
-- Singleton accessor for the TimeSliceScheduler shared by all phases.
-- Set once by the broker at startup, never nilled. No caller dependency.

local registry = {}

function registry.set(scheduler)
  assert(type(scheduler) == "table",
    "scheduler_registry.set() requires a scheduler table")
  registry._instance = scheduler
end

function registry.get()
  return registry._instance
end

return registry
