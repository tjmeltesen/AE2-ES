--[[
buffering.lua -- Phase 1: BUFFERING (extracted from exec_broker.lua)

Monitors the central ME buffer for stability. Polls via bufferFeeder,
feeds data into BufferSnapshot, and transitions to LOGGING when the
snapshot is stable with content.

Dependencies: receives bufferFeeder, snapshot, logger as constructor
arguments -- never reaches into the broker's internals via self._*.

This module is import-safe: require("src.phases.buffering") has no
side effects and does not open modems or start event loops.
]]--

local BufferingPhase = {}
BufferingPhase.__index = BufferingPhase

function BufferingPhase.new(context)
  assert(type(context) == "table", "BufferingPhase requires a context table")
  assert(type(context.bufferFeeder) == "function" or
    context.bufferFeeder == nil,
    "BufferingPhase requires bufferFeeder (function or nil)")
  assert(type(context.snapshot) == "table",
    "BufferingPhase requires snapshot (BufferSnapshot)")
  assert(type(context.logger) == "table" or context.logger == nil,
    "BufferingPhase requires logger (table or nil)")

  return setmetatable({
    _bufferFeeder    = context.bufferFeeder,
    _snapshot        = context.snapshot,
    _logger          = context.logger,
    _enableAutoCrafting = context.enableAutoCrafting or false,
    _autoCraftInputs = context.autoCraftInputs or {},
    _autoCraftPollCount = 0,
    _autoCraftFailures = {},
    _autoCraftCircuits = {},
    _meControllerAddr = context.meControllerAddr or "",
    _hal             = context.hal,
  }, BufferingPhase)
end

--- Poll the central buffer and feed into snapshot.
-- Returns true if snapshot became stable, false if unstable, nil if skipped.
-- @return boolean|nil
function BufferingPhase:pollBuffer()
  if not self._bufferFeeder then return nil end
  local bufferData = self._bufferFeeder()
  if type(bufferData) ~= "table" then
    if self._logger then
      self._logger:warn("BUFFERING: bufferFeeder returned non-table: " .. type(bufferData))
    end
    return nil
  end
  if self._enableAutoCrafting then
    self:_checkAutoCrafting(bufferData)
  end
  return self._snapshot:update(bufferData)
end

--- Execute one tick of the buffering phase.
-- @param pollResult boolean|nil from pollBuffer()
-- @return string next phase ("LOGGING" or "BUFFERING")
function BufferingPhase:execute(pollResult, phases)
  if not self._bufferFeeder then
    if self._logger then
      self._logger:warn("BUFFERING: no bufferFeeder configured")
    end
    return phases.BUFFERING
  end

  if pollResult == nil then
    return phases.BUFFERING
  end

  if not pollResult then
    return phases.BUFFERING
  end

  local snapData = self._snapshot:getSnapshotData()
  if not snapData then
    if self._logger then
      self._logger:warn("BUFFERING: snapshot has no data")
    end
    return phases.BUFFERING
  end

  local hasItems = (snapData.items and #snapData.items > 0)
  local hasFluids = (snapData.fluids and #snapData.fluids > 0)
  if self._logger then
    self._logger:info("BUFFERING: hasItems=" .. tostring(hasItems) ..
      ", hasFluids=" .. tostring(hasFluids))
  end

  if not hasItems and not hasFluids then
    if self._logger then
      self._logger:info("BUFFERING: snapshot is empty, resetting")
    end
    self._snapshot:reset()
    return phases.BUFFERING
  end

  if self._logger then
    self._logger:info("BUFFERING: snapshot is stable with data, transitioning to LOGGING")
  end
  return phases.LOGGING
end

-- Internal: auto-crafting helper (ported from broker)
local function itemCount(items, input)
  local count = 0
  for _, item in ipairs(items or {}) do
    if item.name == input.name and
        (input.damage == nil or item.damage == input.damage) and
        (input.nbt == nil or item.nbt == input.nbt) then
      count = count + (item.size or item.amount or 0)
    end
  end
  return count
end

function BufferingPhase:_checkAutoCrafting(bufferData)
  if not self._enableAutoCrafting or self._meControllerAddr == "" then return end

  self._autoCraftPollCount = self._autoCraftPollCount + 1
  if self._autoCraftPollCount % 5 ~= 0 then return end

  for _, input in ipairs(self._autoCraftInputs) do
    local target = tonumber(input.amount or input.size)
    if type(input.name) == "string" and input.name ~= "" and target and target > 0 then
      local key = input.name
      local available = itemCount(bufferData.items, input)
      if available >= target then
        self._autoCraftFailures[key] = nil
        self._autoCraftCircuits[key] = nil
      elseif not self._autoCraftCircuits[key] then
        local filter = { name = input.name, damage = input.damage, nbt = input.nbt }
        local requested, err = self._hal:requestCraft(
          self._meControllerAddr, filter, target - available)
        local failures = (self._autoCraftFailures[key] or 0) + 1
        self._autoCraftFailures[key] = failures
        if failures >= 3 then
          self._autoCraftCircuits[key] = true
          if self._logger then
            self._logger:warn("AUTO_CRAFT: circuit open for " .. input.name)
          end
        elseif not requested and self._logger then
          self._logger:warn("AUTO_CRAFT: request failed for " .. input.name ..
            ": " .. tostring(err))
        end
      end
    end
  end
end

return BufferingPhase
