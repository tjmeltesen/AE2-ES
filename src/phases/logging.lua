--[[
logging.lua -- Phase 2: LOGGING (extracted from exec_broker.lua)

Converts a stable BufferSnapshot into a JobManifest and pushes it onto
the JobQueue. Resets the snapshot after successful queueing.

Dependencies: receives snapshot, JobManifest constructor, queue,
and logger as constructor arguments.
]]--

local LoggingPhase = {}
LoggingPhase.__index = LoggingPhase

function LoggingPhase.new(context)
  assert(type(context.snapshot) == "table",
    "LoggingPhase requires snapshot (BufferSnapshot)")
  assert(type(context.JobManifest) == "table" and
    type(context.JobManifest.new) == "function",
    "LoggingPhase requires JobManifest constructor")
  assert(type(context.queue) == "table",
    "LoggingPhase requires queue (JobQueue)")
  -- logger is optional
  local logger = context.logger

  return setmetatable({
    _snapshot    = context.snapshot,
    _JobManifest = context.JobManifest,
    _queue       = context.queue,
    _logger      = logger,
  }, LoggingPhase)
end

--- Execute one tick of the logging phase.
-- @param phases table of phase name constants
-- @return string next phase ("ALLOCATING" or "LOGGING" or "BUFFERING")
function LoggingPhase:execute(phases)
  local manifest = self._snapshot:convertToManifest(self._JobManifest, 0)
  if not manifest then
    return phases.BUFFERING
  end

  if self._logger then
    local items = manifest.inputs and manifest.inputs.items
    local fluids = manifest.inputs and manifest.inputs.fluids
    self._logger:info(string.format(
      "LOGGING: manifest %s — items=%d, fluids=%d",
      tostring(manifest.id),
      items and #items or 0,
      fluids and #fluids or 0))
    if items then
      for i, item in ipairs(items) do
        self._logger:info(string.format("  item[%d]: %s x%d", i, item.name or item.label or "?", item.size or 0))
      end
    end
    if fluids then
      for i, fluid in ipairs(fluids) do
        self._logger:info(string.format("  fluid[%d]: %s x%d", i, fluid.name or fluid.label or "?", fluid.amount or 0))
      end
    end
  end

  local job = self._JobManifest.new(manifest.id, manifest.inputs)
  job.priority  = manifest.priority or 0
  job.status    = "PENDING"
  job.createdAt = manifest.createdAt or os.time()
  job.updatedAt = manifest.updatedAt or os.time()

  local pushed = self._queue:push(job)
  if not pushed then
    return phases.LOGGING
  end

  self._snapshot:reset()
  return phases.ALLOCATING
end

return LoggingPhase
