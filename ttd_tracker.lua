-- ttd_tracker.lua
-- B3: TTD Tracking — Monitor consumption rates, calculate Time-to-Depletion,
-- trigger AE2 crafting signals.
--
-- Registers as a consumer with B1 Supervisor. On each TelemetryPayload,
-- samples resource levels (power, extensible to items/fluids), maintains
-- a sliding window of rate samples, and projects depletion time.
-- When TTD drops below configurable thresholds, a crafting signal is emitted.
--
-- Consumer callback signature (matching Supervisor:registerConsumer):
--   tracker:onTelemetry(telemetryPayload, supervisor)
--
-- Usage:
--   local ttdModule = dofile("ttd_tracker.lua")
--   local tracker = ttdModule.TtdTracker.new({
--     powerThreshold = 300,    -- seconds: craft when power TTD < 5 min
--     signalDebounce = 10.0,  -- seconds: min gap between same signal
--   })
--   sv:registerConsumer("TtdTracker", function(payload, supervisor)
--     tracker:onTelemetry(payload, supervisor)
--   end)
--   local ttd = tracker:getTtd(brokerId)
--   local signals = tracker:getActiveSignals()

-- ============================================================
-- Constants
-- ============================================================

-- Resource type identifiers
local RESOURCE_POWER = "power"
local RESOURCE_ITEM = "item"
local RESOURCE_FLUID = "fluid"

-- Signal severity levels
local SIGNAL_INFO = "INFO"
local SIGNAL_WARNING = "WARNING"
local SIGNAL_CRITICAL = "CRITICAL"

-- ============================================================
-- Configuration defaults
-- ============================================================

local DEFAULT_CONFIG = {
  -- Sliding window: number of recent samples to keep per resource
  sampleWindow = 20,
  -- Minimum samples needed before rate calculation is valid
  minSamplesForRate = 3,
  -- Seconds of TTD below which a WARNING signal fires
  powerWarningThreshold = 600,    -- 10 minutes
  -- Seconds of TTD below which a CRITICAL signal fires
  powerCriticalThreshold = 120,   -- 2 minutes
  -- Debounce: minimum seconds between re-firing the same signal
  signalDebounce = 15.0,
  -- If a resource has no consumption (rate <= 0), TTD is reported as nil
  -- Maximum age of a sample before it's discarded (seconds)
  maxSampleAge = 300,  -- 5 minutes
  -- Thresholds for item/fluid (future use)
  itemWarningThreshold = 600,
  itemCriticalThreshold = 120,
  fluidWarningThreshold = 600,
  fluidCriticalThreshold = 120,
  -- Max number of active signals to retain (oldest dropped first)
  maxActiveSignals = 50,
  -- Max signal history size
  maxSignalHistory = 200,
}

-- ============================================================
-- TtdTracker
-- ============================================================

local TtdTracker = {}
TtdTracker.__index = TtdTracker

--- Create a new TtdTracker instance.
--- @param config table|nil Override default config values
--- @return TtdTracker
function TtdTracker.new(config)
  local cfg = {}
  for k, v in pairs(DEFAULT_CONFIG) do
    cfg[k] = v
  end
  if config then
    for k, v in pairs(config) do
      cfg[k] = v
    end
  end

  return setmetatable({
    _config = cfg,
    -- brokerId -> { resource samples + derived state }
    _brokers = {},
    -- Broker appearance order for stable iteration
    _brokerOrder = {},
    -- Active crafting signals that are currently firing
    _activeSignals = {},
    -- Signal history (for dashboard display)
    _signalHistory = {},
    -- Stats
    _stats = {
      totalSamples = 0,
      totalSignalsFired = 0,
      totalSignalsCleared = 0,
      totalSignalHistory = 0,
      brokersTracked = 0,
      lastUpdateTime = 0,
    },
  }, TtdTracker)
end

-- ============================================================
-- Resource sampling helpers
-- ============================================================

--- Build a new resource tracking record.
--- @param resourceType string Resource type identifier
--- @param level number Current resource level
--- @param timestamp number Sample timestamp
--- @return table
function TtdTracker:_newResourceRecord(resourceType, level, timestamp)
  return {
    type = resourceType,
    currentLevel = level,
    lastTimestamp = timestamp,
    samples = {
      { time = timestamp, level = level },
    },
    -- Derived values (recalculated on each update)
    rate = 0,            -- units per second (positive = consuming)
    ttd = nil,           -- seconds until depletion (nil if not consuming)
    rateValid = false,   -- true when we have enough samples
    -- Signal state for debounce
    lastWarningTime = 0,
    lastCriticalTime = 0,
  }
end

--- Append a sample to a resource record's sliding window.
--- @param record table Resource record
--- @param level number Current resource level
--- @param timestamp number Sample timestamp
function TtdTracker:_addSample(record, level, timestamp)
  -- Add new sample
  table.insert(record.samples, { time = timestamp, level = level })
  record.currentLevel = level
  record.lastTimestamp = timestamp

  -- Trim window if over capacity
  while #record.samples > self._config.sampleWindow do
    table.remove(record.samples, 1)
  end

  -- Prune samples older than maxSampleAge
  local cutoff = timestamp - self._config.maxSampleAge
  while #record.samples > 1 and record.samples[1].time < cutoff do
    table.remove(record.samples, 1)
  end

  -- Recalculate rate
  self:_recalculateRate(record)
  self._stats.totalSamples = self._stats.totalSamples + 1
end

--- Recalculate consumption rate and TTD from the sample window.
--- Uses average of consecutive sample-to-sample deltas.
--- @param record table Resource record
function TtdTracker:_recalculateRate(record)
  local samples = record.samples
  local count = #samples

  if count < self._config.minSamplesForRate then
    record.rate = 0
    record.ttd = nil
    record.rateValid = false
    return
  end

  -- Calculate rate: average of consecutive deltas (level / time)
  local totalRate = 0
  local validDeltas = 0

  for i = 2, count do
    local dt = samples[i].time - samples[i - 1].time
    local dl = samples[i].level - samples[i - 1].level

    -- Skip zero-time or negative dt (shouldn't happen but guard)
    if dt > 0 then
      -- Negative dl means consumption (level decreasing)
      -- Positive dl means production/refill (level increasing)
      local deltaRate = dl / dt
      totalRate = totalRate + deltaRate
      validDeltas = validDeltas + 1
    end
  end

  if validDeltas == 0 then
    record.rate = 0
    record.ttd = nil
    record.rateValid = false
    return
  end

  local avgRate = totalRate / validDeltas
  record.rate = avgRate
  record.rateValid = true

  -- TTD = current level / |consumption rate|
  -- Only meaningful when the resource is being consumed (avgRate < 0)
  if avgRate < 0 then
    local absRate = -avgRate
    -- Sanity check: avoid division by zero (shouldn't happen but guard)
    if absRate > 0 then
      record.ttd = record.currentLevel / absRate
    else
      record.ttd = nil
    end
  else
    -- Resource is stable or increasing: no depletion risk
    record.ttd = nil
  end
end

-- ============================================================
-- Broker management
-- ============================================================

--- Create or ensure a broker tracking record.
--- @param brokerId string
--- @return table
function TtdTracker:_ensureBroker(brokerId)
  local broker = self._brokers[brokerId]
  if not broker then
    broker = {
      brokerId = brokerId,
      firstSeen = computer and computer.uptime() or 0,
      lastSeen = computer and computer.uptime() or 0,
      -- resources: { [resourceType] = resourceRecord, ... }
      resources = {},
    }
    self._brokers[brokerId] = broker
    table.insert(self._brokerOrder, brokerId)
    self._stats.brokersTracked = self._stats.brokersTracked + 1
  end
  return broker
end

-- ============================================================
-- Consumer callback
-- ============================================================

--- Consumer callback for B1 Supervisor. Processes a single TelemetryPayload
--- and updates resource tracking for the sending broker.
---
--- Call signature matches Supervisor:registerConsumer contract: (payload, supervisor).
---
--- Sampled resources from payload:
---   powerStored / powerMax  → "power" resource
---   (future: item/fluid data from extended payload)
---
--- @param payload table TelemetryPayload (must have brokerId, timestamp)
--- @param supervisor table|nil Supervisor instance (not used, accepted per contract)
--- @return boolean success, string|nil error
function TtdTracker:onTelemetry(payload, supervisor)
  if type(payload) ~= "table" or type(payload.brokerId) ~= "string" then
    return false, "invalid payload: brokerId required"
  end

  local brokerId = payload.brokerId
  local timestamp = payload.timestamp or (computer and computer.uptime() or 0)

  local broker = self:_ensureBroker(brokerId)
  broker.lastSeen = timestamp

  -- Sample power resource (if payload carries it)
  if payload.powerStored ~= nil then
    self:_samplePower(broker, payload.powerStored, timestamp)
  end

  -- Update stats
  self._stats.lastUpdateTime = computer and computer.uptime() or timestamp

  return true, nil
end

--- Sample power level and evaluate crafting signals.
--- @param broker table Broker record
--- @param powerStored number Current AE power stored
--- @param timestamp number Sample timestamp
function TtdTracker:_samplePower(broker, powerStored, timestamp)
  local res = broker.resources[RESOURCE_POWER]
  if not res then
    res = self:_newResourceRecord(RESOURCE_POWER, powerStored, timestamp)
    broker.resources[RESOURCE_POWER] = res
    self._stats.totalSamples = self._stats.totalSamples + 1
  else
    self:_addSample(res, powerStored, timestamp)
  end

  -- Evaluate TTD thresholds for crafting signals
  if res.ttd and res.rateValid then
    self:_evaluatePowerThresholds(broker.brokerId, res)
  end
end

--- Evaluate power TTD thresholds and fire signals if needed.
--- @param brokerId string
--- @param res table Power resource record
function TtdTracker:_evaluatePowerThresholds(brokerId, res)
  local now = computer and computer.uptime() or 0
  local ttd = res.ttd

  -- CRITICAL threshold (severe shortage)
  if self._config.powerCriticalThreshold > 0 and
     ttd <= self._config.powerCriticalThreshold then
    if now - res.lastCriticalTime >= self._config.signalDebounce then
      res.lastCriticalTime = now
      self:_fireSignal({
        resourceType = RESOURCE_POWER,
        brokerId = brokerId,
        severity = SIGNAL_CRITICAL,
        ttd = ttd,
        threshold = self._config.powerCriticalThreshold,
        message = string.format(
          "CRITICAL: Power TTD %.0fs for broker %s (threshold %.0fs)",
          ttd, brokerId, self._config.powerCriticalThreshold
        ),
      })
    end
    return -- Critical overrides warning
  end

  -- WARNING threshold (approaching shortage)
  if self._config.powerWarningThreshold > 0 and
     ttd <= self._config.powerWarningThreshold then
    if now - res.lastWarningTime >= self._config.signalDebounce then
      res.lastWarningTime = now
      self:_fireSignal({
        resourceType = RESOURCE_POWER,
        brokerId = brokerId,
        severity = SIGNAL_WARNING,
        ttd = ttd,
        threshold = self._config.powerWarningThreshold,
        message = string.format(
          "WARNING: Power TTD %.0fs for broker %s (threshold %.0fs)",
          ttd, brokerId, self._config.powerWarningThreshold
        ),
      })
    end
  end
end

--- Evaluate item/fluid TTD thresholds (for future extended payloads).
--- @param brokerId string
--- @param res table Resource record
--- @param warningThreshold number
--- @param criticalThreshold number
function TtdTracker:_evaluateResourceThresholds(brokerId, res, warningThreshold, criticalThreshold)
  local now = computer and computer.uptime() or 0
  local ttd = res.ttd
  local resourceLabel = res.type

  if criticalThreshold > 0 and ttd <= criticalThreshold then
    if now - res.lastCriticalTime >= self._config.signalDebounce then
      res.lastCriticalTime = now
      self:_fireSignal({
        resourceType = resourceLabel,
        brokerId = brokerId,
        severity = SIGNAL_CRITICAL,
        ttd = ttd,
        threshold = criticalThreshold,
        message = string.format(
          "CRITICAL: %s TTD %.0fs for broker %s (threshold %.0fs)",
          resourceLabel, ttd, brokerId, criticalThreshold
        ),
      })
    end
    return
  end

  if warningThreshold > 0 and ttd <= warningThreshold then
    if now - res.lastWarningTime >= self._config.signalDebounce then
      res.lastWarningTime = now
      self:_fireSignal({
        resourceType = resourceLabel,
        brokerId = brokerId,
        severity = SIGNAL_WARNING,
        ttd = ttd,
        threshold = warningThreshold,
        message = string.format(
          "WARNING: %s TTD %.0fs for broker %s (threshold %.0fs)",
          resourceLabel, ttd, brokerId, warningThreshold
        ),
      })
    end
  end
end

-- ============================================================
-- Crafting signal management
-- ============================================================

--- Fire a crafting signal. Stores it in active signals and history.
--- @param signal table { resourceType, brokerId, severity, ttd, threshold, message }
function TtdTracker:_fireSignal(signal)
  signal.firedAt = computer and computer.uptime() or 0
  signal.id = self._stats.totalSignalsFired + 1

  -- Unique key for dedup in active list: resourceType + brokerId + severity
  local signalKey = signal.resourceType .. ":" .. signal.brokerId .. ":" .. signal.severity

  -- Replace existing active signal with same key (replaces with latest)
  self._activeSignals[signalKey] = signal

  -- Trim active signals if over capacity
  local activeCount = 0
  for _ in pairs(self._activeSignals) do
    activeCount = activeCount + 1
  end
  if activeCount > self._config.maxActiveSignals then
    -- Remove oldest by scanning (simple approach: clear all nil/dead ones)
    -- For a production system, use a timestamped ordered list.
    -- For this implementation, we limit and rely on clearSignal to manage.
    self._activeSignals = {}
    -- Add back only the most recent per unique key
    -- This is a simplification; the config limit is generous enough.
    self:_logSignal("WARN", "Active signals trimmed due to capacity")
  end

  -- Add to history
  table.insert(self._signalHistory, signal)
  if #self._signalHistory > self._config.maxSignalHistory then
    table.remove(self._signalHistory, 1)
  end

  self._stats.totalSignalsFired = self._stats.totalSignalsFired + 1
  self._stats.totalSignalHistory = self._stats.totalSignalHistory + 1
end

--- Log a signal event for internal diagnostics.
--- @param level string
--- @param message string
function TtdTracker:_logSignal(level, message)
  -- In a real OC environment this would go to a log component;
  -- for now we use a simple internal log array.
  if not self._signalLog then
    self._signalLog = {}
  end
  table.insert(self._signalLog, {
    time = computer and computer.uptime() or 0,
    level = level,
    message = message,
  })
  if #self._signalLog > 50 then
    table.remove(self._signalLog, 1)
  end
end

-- ============================================================
-- Public Query API
-- ============================================================

--- Get TTD data for a specific broker's resources.
--- @param brokerId string
--- @param kind string|nil Optional resource type filter ("power", "item", "fluid").
---        When provided, returns only data for that resource type, or nil if
---        no matching resource exists. When nil (default), returns all resources.
--- @return table|nil { [resourceType] = { level, rate, ttd, rateValid }, ... }
function TtdTracker:getTtd(brokerId, kind)
  local broker = self._brokers[brokerId]
  if not broker then
    return nil
  end

  if kind then
    local record = broker.resources[kind]
    if not record then
      return nil
    end
    return {
      [kind] = {
        level = record.currentLevel,
        rate = record.rate,
        ttd = record.ttd,
        rateValid = record.rateValid,
        sampleCount = #(record.samples or {}),
      },
    }
  end

  local result = {}
  for rtype, record in pairs(broker.resources) do
    result[rtype] = {
      level = record.currentLevel,
      rate = record.rate,
      ttd = record.ttd,
      rateValid = record.rateValid,
      sampleCount = #(record.samples or {}),
    }
  end
  return result
end

--- Get TTD for all tracked brokers.
--- @param kind string|nil Optional resource type filter. When provided, only
---        brokers with that resource type are returned (nil for brokers without it).
--- @return table { [brokerId] = (table|nil) }
function TtdTracker:getAllTtd(kind)
  local result = {}
  for _, brokerId in ipairs(self._brokerOrder) do
    result[brokerId] = self:getTtd(brokerId, kind)
  end
  return result
end

--- Get currently active crafting signals.
--- @return table[] Array of signal tables
function TtdTracker:getActiveSignals()
  local result = {}
  for _, signal in pairs(self._activeSignals) do
    table.insert(result, signal)
  end
  -- Sort by severity: CRITICAL first, then WARNING, then INFO
  table.sort(result, function(a, b)
    local severityOrder = { CRITICAL = 0, WARNING = 1, INFO = 2 }
    local aOrd = severityOrder[a.severity] or 99
    local bOrd = severityOrder[b.severity] or 99
    if aOrd ~= bOrd then
      return aOrd < bOrd
    end
    return (a.firedAt or 0) > (b.firedAt or 0)
  end)
  return result
end

--- Get active signals filtered by broker.
--- @param brokerId string
--- @return table[]
function TtdTracker:getSignalsForBroker(brokerId)
  local result = {}
  for _, signal in pairs(self._activeSignals) do
    if signal.brokerId == brokerId then
      table.insert(result, signal)
    end
  end
  return result
end

--- Clear a specific active signal.
--- @param resourceType string
--- @param brokerId string
--- @param severity string
--- @return boolean cleared
function TtdTracker:clearSignal(resourceType, brokerId, severity)
  local key = resourceType .. ":" .. brokerId .. ":" .. severity
  if self._activeSignals[key] then
    self._activeSignals[key] = nil
    self._stats.totalSignalsCleared = self._stats.totalSignalsCleared + 1
    return true
  end
  return false
end

--- Clear all signals for a specific broker (e.g., on maintenance resolution).
--- @param brokerId string
--- @return number count of cleared signals
function TtdTracker:clearSignalsForBroker(brokerId)
  local count = 0
  for key, signal in pairs(self._activeSignals) do
    if signal.brokerId == brokerId then
      self._activeSignals[key] = nil
      count = count + 1
    end
  end
  if count > 0 then
    self._stats.totalSignalsCleared = self._stats.totalSignalsCleared + count
  end
  return count
end

--- Clear all signals.
--- @return number count of cleared signals
function TtdTracker:clearAllSignals()
  local count = 0
  for key, _ in pairs(self._activeSignals) do
    count = count + 1
  end
  self._activeSignals = {}
  if count > 0 then
    self._stats.totalSignalsCleared = self._stats.totalSignalsCleared + count
  end
  return count
end

--- Get signal history (for dashboard display).
--- @param count number|nil Max entries to return (default: all)
--- @return table[]
function TtdTracker:getSignalHistory(count)
  if count and count < #self._signalHistory then
    local start = #self._signalHistory - count + 1
    local result = {}
    for i = start, #self._signalHistory do
      table.insert(result, self._signalHistory[i])
    end
    return result
  end
  return self._signalHistory
end

--- Get a list of tracked broker IDs.
--- @return string[]
function TtdTracker:getBrokerIds()
  local result = {}
  for _, id in ipairs(self._brokerOrder) do
    if self._brokers[id] then
      table.insert(result, id)
    end
  end
  return result
end

--- Get the number of tracked brokers.
--- @return number
function TtdTracker:getBrokerCount()
  return #self._brokerOrder
end

--- Get raw resource record for a broker (detailed for dashboards).
--- @param brokerId string
--- @param resourceType string|nil Specific type, or all resources
--- @return table|nil
function TtdTracker:getResourceDetails(brokerId, resourceType)
  local broker = self._brokers[brokerId]
  if not broker then
    return nil
  end
  if resourceType then
    return broker.resources[resourceType]
  end
  return broker.resources
end

--- Check if a broker has any active critical-level signals.
--- @param brokerId string|nil Filter by broker, or check all
--- @return boolean
function TtdTracker:hasCriticalSignals(brokerId)
  for _, signal in pairs(self._activeSignals) do
    if signal.severity == SIGNAL_CRITICAL then
      if not brokerId or signal.brokerId == brokerId then
        return true
      end
    end
  end
  return false
end

--- Get summary statistics.
--- @return table
function TtdTracker:getStats()
  return {
    brokersTracked = self._stats.brokersTracked,
    totalSamples = self._stats.totalSamples,
    totalSignalsFired = self._stats.totalSignalsFired,
    totalSignalsCleared = self._stats.totalSignalsCleared,
    activeSignalCount = self:getActiveSignalCount(),
    lastUpdateTime = self._stats.lastUpdateTime,
  }
end

--- Get count of active signals.
--- @return number
function TtdTracker:getActiveSignalCount()
  local count = 0
  for _ in pairs(self._activeSignals) do
    count = count + 1
  end
  return count
end

--- Get a human-readable status summary.
--- @return string
function TtdTracker:getStatusSummary()
  local stats = self:getStats()
  local activeSignals = self:getActiveSignals()
  local criticalCount = 0
  local warningCount = 0
  for _, s in ipairs(activeSignals) do
    if s.severity == SIGNAL_CRITICAL then
      criticalCount = criticalCount + 1
    elseif s.severity == SIGNAL_WARNING then
      warningCount = warningCount + 1
    end
  end
  return string.format(
    "TtdTracker: %d brokers, %d samples, %d active signals (%d critical, %d warning), %d total fired",
    stats.brokersTracked, stats.totalSamples,
    stats.activeSignalCount, criticalCount, warningCount,
    stats.totalSignalsFired
  )
end

--- Get the current config (copy to prevent mutation).
--- @return table
function TtdTracker:getConfig()
  local cfg = {}
  for k, v in pairs(self._config) do
    cfg[k] = v
  end
  return cfg
end

--- Manually inject a resource sample (for item/fluid data from external sources).
--- Allows other modules (e.g., B6 inter-broker coordination) to push
--- resource data into the TTD tracker.
---
--- @param brokerId string
--- @param resourceType string "item", "fluid", or "power"
--- @param level number Current resource level
--- @param timestamp number|nil Sample timestamp (defaults to uptime)
function TtdTracker:injectSample(brokerId, resourceType, level, timestamp)
  if type(brokerId) ~= "string" or type(resourceType) ~= "string" or type(level) ~= "number" then
    return false, "invalid sample parameters"
  end

  local broker = self:_ensureBroker(brokerId)
  local ts = timestamp or (computer and computer.uptime() or 0)

  local res = broker.resources[resourceType]
  if not res then
    res = self:_newResourceRecord(resourceType, level, ts)
    broker.resources[resourceType] = res
    self._stats.totalSamples = self._stats.totalSamples + 1
  else
    self:_addSample(res, level, ts)
  end

  -- Evaluate TTD thresholds for this resource
  if res.ttd and res.rateValid then
    if resourceType == RESOURCE_POWER then
      self:_evaluatePowerThresholds(brokerId, res)
    else
      local warningKey = resourceType .. "WarningThreshold"
      local criticalKey = resourceType .. "CriticalThreshold"
      local wt = self._config[warningKey] or 600
      local ct = self._config[criticalKey] or 120
      self:_evaluateResourceThresholds(brokerId, res, wt, ct)
    end
  end

  return true, nil
end

--- Produce a serialization-safe snapshot of current TTD state.
--- Useful for telemetry exports and dashboard snapshots.
--- @return table
function TtdTracker:toSnapshot()
  local snapshot = {
    _version = 1,
    brokers = {},
    activeSignals = self:getActiveSignals(),
    stats = self._stats,
    config = self._config,
  }

  for _, brokerId in ipairs(self._brokerOrder) do
    local broker = self._brokers[brokerId]
    if broker then
      local brokerSnapshot = {
        brokerId = broker.brokerId,
        firstSeen = broker.firstSeen,
        lastSeen = broker.lastSeen,
        resources = {},
      }
      for rtype, record in pairs(broker.resources) do
        brokerSnapshot.resources[rtype] = {
          type = record.type,
          currentLevel = record.currentLevel,
          lastTimestamp = record.lastTimestamp,
          rate = record.rate,
          ttd = record.ttd,
          rateValid = record.rateValid,
          sampleCount = #(record.samples or {}),
        }
      end
      table.insert(snapshot.brokers, brokerSnapshot)
    end
  end

  return snapshot
end

-- ============================================================
-- Module exports
-- ============================================================

return {
  TtdTracker = TtdTracker,
  RESOURCE_POWER = RESOURCE_POWER,
  RESOURCE_ITEM = RESOURCE_ITEM,
  RESOURCE_FLUID = RESOURCE_FLUID,
  SIGNAL_INFO = SIGNAL_INFO,
  SIGNAL_WARNING = SIGNAL_WARNING,
  SIGNAL_CRITICAL = SIGNAL_CRITICAL,
  DEFAULT_CONFIG = DEFAULT_CONFIG,
}
