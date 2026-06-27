-- ttd_tracker_test.lua
-- B3: TTD Tracking — Unit test suite for TtdTracker
-- Tests resource sampling, rate calculation, TTD projection,
-- crafting signal generation, debounce, and edge cases.
--
-- Run: lua ttd_tracker_test.lua

-- Mock the computer module for environments that don't have it
local MockComputer = { _uptime = 1000.0 }
function MockComputer.uptime()
  return MockComputer._uptime
end
computer = computer or MockComputer

local ttdModule = dofile("ttd_tracker.lua")
local TtdTracker = ttdModule.TtdTracker

local testsRun = 0
local testsPassed = 0
local testsFailed = 0

-- Test helper
local function test(name, fn)
  testsRun = testsRun + 1
  local ok, err = pcall(fn)
  if ok then
    testsPassed = testsPassed + 1
    io.write(string.format("  PASS: %s\n", name))
  else
    testsFailed = testsFailed + 1
    io.write(string.format("  FAIL: %s -- %s\n", name, tostring(err)))
  end
end

-- Helper: create a TelemetryPayload-like table
local function makePayload(brokerId, powerStored, timestamp)
  return {
    brokerId = brokerId or "test-broker-1",
    timestamp = timestamp or MockComputer._uptime,
    hardwareMatrix = {},
    alerts = {},
    powerStored = powerStored,
  }
end

-- Helper: advance mock time
local function advance(seconds)
  MockComputer._uptime = MockComputer._uptime + seconds
end

-- Helper: set absolute time
local function setTime(t)
  MockComputer._uptime = t
end

-- ============================================================
-- Test group 1: Constructor & Configuration
-- ============================================================

test("constructor with defaults", function()
  local tracker = TtdTracker.new()
  local cfg = tracker:getConfig()
  assert(cfg.sampleWindow == 20, "default sampleWindow should be 20")
  assert(cfg.minSamplesForRate == 3, "default minSamplesForRate should be 3")
  assert(cfg.powerWarningThreshold == 600, "default powerWarningThreshold should be 600")
  assert(cfg.powerCriticalThreshold == 120, "default powerCriticalThreshold should be 120")
  assert(cfg.signalDebounce == 15.0, "default signalDebounce should be 15.0")
  assert(tracker:getBrokerCount() == 0, "no brokers initially")
  local stats = tracker:getStats()
  assert(stats.totalSamples == 0, "no samples initially")
  assert(stats.totalSignalsFired == 0, "no signals fired")
  assert(stats.brokersTracked == 0, "no brokers tracked")
end)

test("constructor with custom config", function()
  local tracker = TtdTracker.new({
    sampleWindow = 10,
    minSamplesForRate = 2,
    powerWarningThreshold = 300,
    powerCriticalThreshold = 60,
    signalDebounce = 5.0,
  })
  local cfg = tracker:getConfig()
  assert(cfg.sampleWindow == 10, "custom sampleWindow")
  assert(cfg.minSamplesForRate == 2, "custom minSamplesForRate")
  assert(cfg.powerWarningThreshold == 300, "custom powerWarningThreshold")
  assert(cfg.powerCriticalThreshold == 60, "custom powerCriticalThreshold")
  assert(cfg.signalDebounce == 5.0, "custom signalDebounce")
end)

test("constructor partial config merge", function()
  local tracker = TtdTracker.new({ powerWarningThreshold = 100 })
  local cfg = tracker:getConfig()
  assert(cfg.powerWarningThreshold == 100, "overridden threshold")
  assert(cfg.sampleWindow == 20, "default sampleWindow preserved")
  assert(cfg.minSamplesForRate == 3, "default minSamplesForRate preserved")
end)

-- ============================================================
-- Test group 2: Resource Sampling & Rate Calculation
-- ============================================================

test("first telemetry creates broker and resource", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ok, err = tracker:onTelemetry(makePayload("broker-A", 8000))
  assert(ok, "onTelemetry should succeed")

  local ttd = tracker:getTtd("broker-A")
  assert(ttd ~= nil, "broker should exist")
  assert(ttd.power ~= nil, "power resource should exist")
  assert(ttd.power.level == 8000, "power level should be 8000")
  assert(ttd.power.rate == 0, "rate should be 0 with single sample")
  assert(ttd.power.rateValid == false, "rate should not be valid with 1 sample")
  assert(ttd.power.ttd == nil, "TTD should be nil with insufficient samples")
  assert(tracker:getBrokerCount() == 1, "one broker tracked")
end)

test("two samples: still insufficient for rate", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power.rateValid == false, "rate should not be valid with 2 samples (min=3)")
end)

test("three samples with consumption calculates rate and TTD", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  -- Power: 8000 -> 7900 -> 7800 (100 units consumed per 10 sec = 10/sec)
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power.rateValid == true, "rate should be valid")
  assert(math.abs(ttd.power.rate - (-10)) < 0.01, "rate should be -10 units/sec")
  -- TTD = 7800 / 10 = 780 seconds
  assert(ttd.power.ttd ~= nil, "TTD should be computed")
  assert(math.abs(ttd.power.ttd - 780) < 0.5, "TTD should be ~780 seconds")
end)

test("variable consumption rate averages correctly", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  -- 8000 -> 7800 (-200/10s = -20/s)
  -- 7800 -> 7700 (-100/10s = -10/s)
  -- Average: (-20 + -10) / 2 = -15/s
  -- TTD = 7700 / 15 = 513.3s
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7700))

  local ttd = tracker:getTtd("broker-A")
  assert(math.abs(ttd.power.rate - (-15)) < 0.01, "avg rate should be -15/s")
  assert(math.abs(ttd.power.ttd - 513.33) < 0.5, "TTD should be ~513.3s")
end)

test("stable power (no consumption) gives nil TTD", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 8000))

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power.rateValid == true, "rate valid")
  assert(math.abs(ttd.power.rate) < 0.01, "rate should be ~0")
  assert(ttd.power.ttd == nil, "TTD should be nil when not consuming")
end)

test("recharging power (rate positive) gives nil TTD", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 5000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7000))

  local ttd = tracker:getTtd("broker-A")
  assert(math.abs(ttd.power.rate - 100) < 0.01, "rate should be +100/s")
  assert(ttd.power.ttd == nil, "TTD should be nil when recharging")
end)

test("sliding window: old samples are trimmed", function()
  setTime(1000)
  local tracker = TtdTracker.new({ sampleWindow = 5, minSamplesForRate = 3 })
  -- Add 10 samples
  for i = 1, 10 do
    tracker:onTelemetry(makePayload("broker-A", 8000 - (i * 100)))
    advance(10)
  end
  local ttd = tracker:getTtd("broker-A")
  -- Should only have 5 samples due to window
  assert(ttd.power.sampleCount == 5, "should only have 5 samples after window trim")
end)

test("samples older than maxSampleAge are pruned", function()
  setTime(1000)
  local tracker = TtdTracker.new({ maxSampleAge = 60, minSamplesForRate = 2 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  local ttd1 = tracker:getTtd("broker-A")
  assert(ttd1.power.sampleCount == 3, "three samples before pruning")

  -- Advance past maxSampleAge
  advance(70)
  tracker:onTelemetry(makePayload("broker-A", 7700))

  local ttd2 = tracker:getTtd("broker-A")
  -- Old samples should be pruned (those > 60s old)
  -- At time 1090 with cutoff 1030: only the newest sample (1090) survives
  assert(ttd2.power.sampleCount == 1, "old samples pruned, only 1 recent remains")
end)

-- ============================================================
-- Test group 3: Multiple Brokers
-- ============================================================

test("multiple brokers tracked independently", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })

  -- Broker A: consuming power
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  -- Broker B: stable power
  tracker:onTelemetry(makePayload("broker-B", 10000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-B", 10000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-B", 10000))

  assert(tracker:getBrokerCount() == 2, "two brokers tracked")

  local ttdA = tracker:getTtd("broker-A")
  local ttdB = tracker:getTtd("broker-B")

  assert(math.abs(ttdA.power.rate - (-10)) < 0.01, "broker-A rate")
  assert(ttdA.power.ttd ~= nil, "broker-A TTD present")
  assert(math.abs(ttdB.power.rate) < 0.01, "broker-B rate ~0")
  assert(ttdB.power.ttd == nil, "broker-B TTD nil (stable)")
end)

test("getTtd returns nil for unknown broker", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ttd = tracker:getTtd("nonexistent")
  assert(ttd == nil, "unknown broker should return nil")
end)

test("getAllTtd returns all brokers", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7800))
  tracker:onTelemetry(makePayload("broker-B", 5000))

  local all = tracker:getAllTtd()
  assert(all["broker-A"] ~= nil, "broker-A in all")
  assert(all["broker-B"] ~= nil, "broker-B in all")
  assert(tracker:getBrokerCount() == 2, "broker count is 2")
end)

-- ============================================================
-- Test group 3b: getTtd / getAllTtd with kind filter
-- ============================================================

test("getTtd with kind='power' returns only power data", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  -- Add power + item resources via telemetry + inject
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7800))
  tracker:injectSample("broker-A", "item", 1000, 1010)
  advance(10)
  tracker:injectSample("broker-A", "item", 800, 1020)
  advance(10)
  tracker:injectSample("broker-A", "item", 600, 1030)

  local powerOnly = tracker:getTtd("broker-A", "power")
  assert(powerOnly ~= nil, "power result should exist")
  assert(powerOnly.power ~= nil, "power resource returned")
  assert(powerOnly.item == nil, "item resource should NOT be returned")
  assert(powerOnly.power.level == 7800, "correct power level")

  local itemOnly = tracker:getTtd("broker-A", "item")
  assert(itemOnly ~= nil, "item result should exist")
  assert(itemOnly.item ~= nil, "item resource returned")
  assert(itemOnly.power == nil, "power resource should NOT be returned")
  assert(itemOnly.item.level == 600, "correct item level")
end)

test("getTtd with kind returns nil when broker has no such resource", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  local fluidData = tracker:getTtd("broker-A", "fluid")
  assert(fluidData == nil, "fluid data should be nil for broker with only power")
end)

test("getTtd with kind returns nil for unknown broker", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ttd = tracker:getTtd("nonexistent", "power")
  assert(ttd == nil, "unknown broker should return nil even with kind filter")
end)

test("getAllTtd with kind='power' returns only power data per broker", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  -- Broker A: power + items
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7800))
  tracker:injectSample("broker-A", "item", 500, 1010)
  advance(5)
  tracker:injectSample("broker-A", "item", 400, 1020)
  advance(5)
  tracker:injectSample("broker-A", "item", 300, 1030)
  -- Broker B: power only
  tracker:onTelemetry(makePayload("broker-B", 10000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-B", 9900))
  advance(5)
  tracker:onTelemetry(makePayload("broker-B", 9800))

  local allPower = tracker:getAllTtd("power")
  assert(allPower["broker-A"] ~= nil, "broker-A in allPower")
  assert(allPower["broker-B"] ~= nil, "broker-B in allPower")
  assert(allPower["broker-A"].power ~= nil, "broker-A power present")
  assert(allPower["broker-A"].item == nil, "broker-A item filtered out")
  assert(allPower["broker-A"].power.rateValid == true, "broker-A power rate valid")

  local allItem = tracker:getAllTtd("item")
  assert(allItem["broker-A"] ~= nil, "broker-A in allItem (has items)")
  assert(allItem["broker-B"] == nil, "broker-B has no items, should be nil")
  assert(allItem["broker-A"].item ~= nil, "broker-A item present")
  assert(allItem["broker-A"].item.level == 300, "broker-A item level 300")
  assert(allItem["broker-A"].power == nil, "broker-A power filtered out")
end)

test("getTtd without kind still returns all resources (backward compat)", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7800))
  tracker:injectSample("broker-A", "item", 500, 1010)

  local all = tracker:getTtd("broker-A")
  assert(all ~= nil, "broker-A exists")
  assert(all.power ~= nil, "power resource included")
  assert(all.item ~= nil, "item resource included")
  assert(all.power.rateValid == true, "power rate valid")
  assert(all.item.level == 500, "item level correct")
end)

-- ============================================================
-- Test group 4: Crafting Signal Generation
-- ============================================================

test("warning signal fires when TTD below warning threshold", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,  -- disable critical for this test
    signalDebounce = 0,  -- no debounce for this test
  })
  -- Consume quickly: 8000 -> 7000 over 20 sec = -50/s
  -- TTD at end: 7000 / 50 = 140s (well below 600s warning threshold)
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7500))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7000))

  local signals = tracker:getActiveSignals()
  local found = false
  for _, s in ipairs(signals) do
    if s.resourceType == "power" and s.brokerId == "broker-A" then
      found = true
      assert(s.severity == "WARNING", "should be WARNING severity")
      assert(s.ttd ~= nil, "signal should have TTD")
      assert(s.message:find("WARNING"), "message should start with WARNING")
      break
    end
  end
  assert(found, "warning signal should be active")
end)

test("critical signal fires when TTD below critical threshold", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 200,
    signalDebounce = 0,
  })
  -- Consume very quickly: 8000 -> 1000 over 30 sec = -233.3/s
  -- TTD at end: 1000 / 233.3 = 4.3s (well below 200s critical)
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 2000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 1000))

  local signals = tracker:getActiveSignals()
  local foundCritical = false
  for _, s in ipairs(signals) do
    if s.resourceType == "power" and s.brokerId == "broker-A" and s.severity == "CRITICAL" then
      foundCritical = true
      assert(s.ttd ~= nil, "critical signal should have TTD")
      break
    end
  end
  assert(foundCritical, "critical signal should be active")
end)

test("no signal when TTD above both thresholds", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 120,
    signalDebounce = 0,
  })
  -- Very slow consumption: 8000 -> 7950 over 20 sec = -2.5/s
  -- TTD at end: 7950 / 2.5 = 3180s (above both thresholds)
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7975))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7950))

  local signals = tracker:getActiveSignals()
  assert(#signals == 0, "no signals should fire when TTD is above thresholds")
end)

test("critical overrides warning (only critical fires)", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 200,
    signalDebounce = 0,
  })
  -- Fast consumption produces TTD below both thresholds
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 2000))

  local signals = tracker:getActiveSignals()
  local criticalCount = 0
  local warningCount = 0
  for _, s in ipairs(signals) do
    if s.severity == "CRITICAL" then criticalCount = criticalCount + 1 end
    if s.severity == "WARNING" then warningCount = warningCount + 1 end
  end
  assert(criticalCount >= 1, "critical signal should fire")
  assert(warningCount == 0, "warning should NOT fire when critical is active")
end)

test("signal fires without debounce (debounce=0)", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,
    signalDebounce = 0,
  })
  -- Fast consumption
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  advance(5)
  -- More telemetry comes in, still below threshold
  tracker:onTelemetry(makePayload("broker-A", 2000))

  local signals = tracker:getActiveSignals()
  assert(#signals >= 1, "signal active")
  -- Signal count should still be 1 per unique key because we replace
  -- Verify it's the most recent
  assert(signals[1].severity == "WARNING", "warning signal")
end)

test("signal debounce prevents re-firing within debounce window", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,
    signalDebounce = 30,
  })
  -- Fast consumption below threshold
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 2000))

  local signals1 = tracker:getActiveSignals()
  assert(#signals1 == 1, "one signal after first threshold crossing")

  -- Advance only 10s (less than 30s debounce), send more data
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 1000))

  -- Should still only have 1 signal (debounced)
  local signals2 = tracker:getActiveSignals()
  assert(#signals2 == 1, "signal still debounced")
  assert(tracker:getStats().totalSignalsFired == 1, "no new signals fired")
end)

test("signal re-fires after debounce window expires", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 2,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,
    signalDebounce = 15,
  })
  -- MinSamplesForRate=2: first signal after 2 consumption samples
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))

  assert(tracker:getStats().totalSignalsFired == 1, "first signal fired")

  -- Advance past debounce window
  advance(20)
  tracker:onTelemetry(makePayload("broker-A", 5500))

  -- Should fire again since debounce expired
  local stats = tracker:getStats()
  assert(stats.totalSignalsFired == 2, "second signal should fire after debounce")
end)

-- ============================================================
-- Test group 5: Signal Management
-- ============================================================

test("clearSignal removes specific signal", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,
    signalDebounce = 0,
  })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))

  assert(tracker:getActiveSignalCount() == 1, "one active signal")

  local cleared = tracker:clearSignal("power", "broker-A", "WARNING")
  assert(cleared == true, "signal should be cleared")
  assert(tracker:getActiveSignalCount() == 0, "no active signals after clear")
end)

test("clearSignal returns false for nonexistent signal", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local cleared = tracker:clearSignal("power", "unknown", "WARNING")
  assert(cleared == false, "nonexistent signal returns false")
end)

test("clearSignalsForBroker removes all signals for a broker", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    signalDebounce = 0,
  })
  -- Create signals for two brokers
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  tracker:onTelemetry(makePayload("broker-B", 5000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-B", 4000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-B", 3000))

  assert(tracker:getActiveSignalCount() == 2, "two active signals initially")
  local count = tracker:clearSignalsForBroker("broker-A")
  assert(count >= 1, "cleared at least one signal for broker-A")
  assert(tracker:getActiveSignalCount() == 1, "one signal remains for broker-B")
end)

test("clearAllSignals removes all signals", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    signalDebounce = 0,
  })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))

  assert(tracker:getActiveSignalCount() > 0, "signals exist")

  local count = tracker:clearAllSignals()
  assert(count > 0, "cleared signals")
  assert(tracker:getActiveSignalCount() == 0, "no signals after clearAll")
end)

test("getSignalsForBroker filtered correctly", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    signalDebounce = 0,
  })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  tracker:onTelemetry(makePayload("broker-B", 5000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-B", 4000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-B", 3000))

  local brokerASignals = tracker:getSignalsForBroker("broker-A")
  local brokerBSignals = tracker:getSignalsForBroker("broker-B")
  assert(#brokerASignals == 1, "one signal for broker-A")
  assert(#brokerBSignals == 1, "one signal for broker-B")
  assert(brokerASignals[1].brokerId == "broker-A", "correct broker")
end)

test("hasCriticalSignals detects critical", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 200,
    signalDebounce = 0,
  })
  -- Fast consumption to trigger critical
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 1000))

  assert(tracker:hasCriticalSignals() == true, "critical signals exist")
  assert(tracker:hasCriticalSignals("broker-A") == true, "critical for broker-A")
  assert(tracker:hasCriticalSignals("broker-B") == false, "no critical for broker-B")
end)

-- ============================================================
-- Test group 6: Signal History
-- ============================================================

test("signal history records fired signals", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,
    signalDebounce = 0,
  })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))

  local history = tracker:getSignalHistory()
  assert(#history == 1, "one signal in history")
  assert(history[1].brokerId == "broker-A", "correct broker in history")
  assert(history[1].resourceType == "power", "correct resource type")
  assert(history[1].id ~= nil, "signal has id")
end)

test("signal history respects maxSignalHistory", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    maxSignalHistory = 3,
    minSamplesForRate = 2,
    powerWarningThreshold = 600,
    powerCriticalThreshold = 0,
    signalDebounce = 0,
  })
  -- Fire multiple signals by repeatedly advancing and sampling
  for i = 1, 6 do
    tracker:onTelemetry(makePayload("broker-A", 8000 - (i * 1000)))
    advance(5)
    tracker:onTelemetry(makePayload("broker-A", 7000 - (i * 1000)))
    advance(5)
  end

  local history = tracker:getSignalHistory()
  assert(#history <= 3, "history should be trimmed to maxSignalHistory")
end)

test("getSignalHistory with count parameter", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 2,
    powerWarningThreshold = 600,
    signalDebounce = 0,
  })
  -- Fire 3 signals
  for i = 1, 3 do
    tracker:onTelemetry(makePayload("broker-A", 8000 - (i * 1000)))
    advance(5)
    tracker:onTelemetry(makePayload("broker-A", 7000 - (i * 1000)))
    advance(5)
  end

  local lastTwo = tracker:getSignalHistory(2)
  assert(#lastTwo == 2, "should return only 2 entries")
end)

-- ============================================================
-- Test group 7: injectSample API
-- ============================================================

test("injectSample for power resource", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })

  local ok, err = tracker:injectSample("broker-A", "power", 8000)
  assert(ok, "inject should succeed")
  advance(10)
  tracker:injectSample("broker-A", "power", 7900)
  advance(10)
  tracker:injectSample("broker-A", "power", 7800)

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power.rateValid == true, "rate valid via injectSample")
  assert(math.abs(ttd.power.rate - (-10)) < 0.01, "rate -10/s via injectSample")
end)

test("injectSample for item resource", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })

  tracker:injectSample("broker-A", "item", 640, 1000)
  advance(10)
  tracker:injectSample("broker-A", "item", 580, 1010)
  advance(10)
  tracker:injectSample("broker-A", "item", 520, 1020)

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.item ~= nil, "item resource should exist")
  assert(ttd.item.level == 520, "item level correct")
  assert(ttd.item.rateValid == true, "item rate valid")
  assert(math.abs(ttd.item.rate - (-6)) < 0.01, "item rate -6/s")
  -- TTD = 520/6 = 86.67s
  assert(ttd.item.ttd ~= nil, "item TTD should be computed")
  assert(math.abs(ttd.item.ttd - 86.67) < 0.5, "item TTD ~86.67s")
end)

test("injectSample for fluid resource", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })

  tracker:injectSample("broker-A", "fluid", 10000, 1000)
  advance(30)
  tracker:injectSample("broker-A", "fluid", 8500, 1030)
  advance(30)
  tracker:injectSample("broker-A", "fluid", 7000, 1060)

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.fluid ~= nil, "fluid resource should exist")
  -- Rate: (8500-10000)/30 + (7000-8500)/30 = -50 + -50 = -100
  -- Average = -100/2 = -50/s
  assert(ttd.fluid.rateValid == true, "fluid rate valid")
  -- TTD at 7000 / 50 = 140
  assert(ttd.fluid.ttd ~= nil, "fluid TTD")
  assert(math.abs(ttd.fluid.ttd - 140) < 0.5, "fluid TTD ~140s")
end)

test("injectSample with invalid params", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ok1, _ = tracker:injectSample(nil, "power", 8000)
  assert(ok1 == false, "nil brokerId should fail")
  local ok2, _ = tracker:injectSample("broker-A", nil, 8000)
  assert(ok2 == false, "nil resourceType should fail")
  local ok3, _ = tracker:injectSample("broker-A", "power", "8000")
  assert(ok3 == false, "string level should fail")
end)

-- ============================================================
-- Test group 8: Edge Cases
-- ============================================================

test("onTelemetry with nil payload", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ok, err = tracker:onTelemetry(nil)
  assert(ok == false, "nil payload should fail")
  assert(err ~= nil, "should return error")
end)

test("onTelemetry with no brokerId", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ok, err = tracker:onTelemetry({})
  assert(ok == false, "payload without brokerId should fail")
end)

test("onTelemetry with no powerStored", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local ok, err = tracker:onTelemetry({
    brokerId = "broker-A",
    timestamp = 1000,
    hardwareMatrix = {},
    alerts = {},
  })
  assert(ok == true, "payload without powerStored should succeed")
  -- No resources should be tracked
  local ttd = tracker:getTtd("broker-A")
  assert(ttd ~= nil, "broker should exist")
  assert(ttd.power == nil, "no power resource without powerStored")
end)

test("TTD from two brokers with injectSample + telemetry", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })

  -- Broker A via telemetry
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  -- Broker B via injectSample (items)
  tracker:injectSample("broker-B", "item", 1000, 1020)
  advance(10)
  tracker:injectSample("broker-B", "item", 800, 1030)
  advance(10)
  tracker:injectSample("broker-B", "item", 600, 1040)

  local allTtd = tracker:getAllTtd()
  assert(allTtd["broker-A"] ~= nil, "broker-A present")
  assert(allTtd["broker-B"] ~= nil, "broker-B present")
  assert(allTtd["broker-A"].power ~= nil, "broker-A has power")
  assert(allTtd["broker-B"].item ~= nil, "broker-B has item")
end)

test("single sample after many still has invalid rate", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  -- Only one sample, no rate possible
  tracker:onTelemetry(makePayload("broker-A", 8000))
  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power.rateValid == false, "rate invalid with one sample")
  assert(ttd.power.ttd == nil, "TTD nil with one sample")
end)

test("zero powerStored does not cause errors", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 0))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 0))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 0))

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power.rateValid == true, "rate valid with zero power")
  assert(ttd.power.ttd == nil, "TTD nil with zero consumption")
end)

test("resourceDetails API", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  local details = tracker:getResourceDetails("broker-A", "power")
  assert(details ~= nil, "power details exist")
  assert(details.type == "power", "type is power")
  assert(details.currentLevel == 7800, "current level")

  local allResources = tracker:getResourceDetails("broker-A")
  assert(allResources ~= nil, "all resources non-nil")
  assert(allResources.power ~= nil, "power in all resources")
end)

test("getBrokerIds returns ordered list", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  tracker:onTelemetry(makePayload("broker-A", 8000))
  tracker:onTelemetry(makePayload("broker-B", 8000))
  tracker:onTelemetry(makePayload("broker-C", 8000))
  tracker:onTelemetry(makePayload("broker-A", 7000))  -- duplicate, no reorder

  local ids = tracker:getBrokerIds()
  assert(#ids == 3, "three broker IDs")
  assert(ids[1] == "broker-A", "broker-A first")
  assert(ids[2] == "broker-B", "broker-B second")
  assert(ids[3] == "broker-C", "broker-C third")
end)

-- ============================================================
-- Test group 9: Config & Stats
-- ============================================================

test("getConfig returns a copy (immutable)", function()
  setTime(1000)
  local tracker = TtdTracker.new()
  local cfg = tracker:getConfig()
  cfg.powerWarningThreshold = 9999
  local cfg2 = tracker:getConfig()
  assert(cfg2.powerWarningThreshold == 600, "config should not be mutated")
end)

test("getStats reflects activity", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7500))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7000))

  local stats = tracker:getStats()
  assert(stats.brokersTracked == 1, "one broker")
  assert(stats.totalSamples == 3, "three samples")
  assert(stats.activeSignalCount ==
         tracker:getActiveSignalCount(), "active signal count matches")
end)

-- ============================================================
-- Test group 10: toSnapshot
-- ============================================================

test("toSnapshot includes all data", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  local snapshot = tracker:toSnapshot()
  assert(snapshot._version == 1, "version marker present")
  assert(#snapshot.brokers == 1, "one broker in snapshot")
  assert(snapshot.brokers[1].brokerId == "broker-A", "correct broker id")
  assert(snapshot.brokers[1].resources.power ~= nil, "power resource in snapshot")
  assert(snapshot.brokers[1].resources.power.currentLevel == 7800, "correct power level")
  assert(snapshot.brokers[1].resources.power.sampleCount == 3, "three samples")
  assert(snapshot.stats.totalSamples == 3, "stats in snapshot")
  assert(snapshot.stats.totalSignalsFired == 0, "no signals")
end)

test("toSnapshot includes active signals", function()
  setTime(1000)
  local tracker = TtdTracker.new({
    minSamplesForRate = 3,
    powerWarningThreshold = 600,
    signalDebounce = 0,
  })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 6000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 4000))

  local snapshot = tracker:toSnapshot()
  assert(#snapshot.activeSignals >= 1, "active signals in snapshot")
end)

-- ============================================================
-- Test group 11: Status Summary
-- ============================================================

test("getStatusSummary returns formatted string", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7500))
  advance(5)
  tracker:onTelemetry(makePayload("broker-A", 7000))

  local summary = tracker:getStatusSummary()
  assert(type(summary) == "string", "summary is a string")
  assert(summary:find("TtdTracker:"), "summary starts with TtdTracker:")
  assert(summary:find("1 broker"), "summary mentions 1 broker")
  assert(summary:find("3 samples"), "summary mentions 3 samples")
end)

-- ============================================================
-- Test group 12: Large & Stress Tests
-- ============================================================

test("100 rapid telemetry payloads", function()
  setTime(1000)
  local tracker = TtdTracker.new({ sampleWindow = 50, minSamplesForRate = 3 })

  -- Power dropping from 8000 to 0 over 100 samples
  for i = 1, 100 do
    local level = 8000 - (i * 80)
    if level < 0 then level = 0 end
    tracker:onTelemetry(makePayload("stress-broker", level))
    advance(1)
  end

  local stats = tracker:getStats()
  assert(stats.totalSamples == 100, "100 samples recorded")
  assert(stats.brokersTracked == 1, "one broker")
  local ttd = tracker:getTtd("stress-broker")
  assert(ttd.power ~= nil, "power resource exists")
  assert(ttd.power.sampleCount <= 50, "window trimmed to 50")
  print(string.format("    INFO: 100 samples: rate=%.2f/s, TTD=%.1fs, samples=%d",
    ttd.power.rate, ttd.power.ttd or -1, ttd.power.sampleCount))
end)

test("alternating brokers", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  for i = 1, 10 do
    local broker = "broker-" .. ((i % 3) + 1)
    tracker:onTelemetry(makePayload(broker, 8000 - (i * 100)))
    advance(2)
  end
  assert(tracker:getBrokerCount() == 3, "three brokers after alternating")
  local stats = tracker:getStats()
  assert(stats.totalSamples == 10, "10 total samples")
end)

-- ============================================================
-- Test group 13: Consumer Registration Pattern
-- ============================================================

test("registers as supervisor consumer successfully", function()
  setTime(1000)
  -- Simulate the Supervisor:registerConsumer pattern:
  --   sv:registerConsumer("TtdTracker", function(payload, sv)
  --     tracker:onTelemetry(payload, sv)
  --   end)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })

  -- Simulate the registration and callback (as B1 Supervisor would call it)
  local callback = function(payload, supervisor)
    return tracker:onTelemetry(payload, supervisor)
  end

  local ok, err = callback(makePayload("broker-A", 8000), nil)
  assert(ok, "consumer callback succeeds")
  advance(10)
  callback(makePayload("broker-A", 7900), nil)
  advance(10)
  callback(makePayload("broker-A", 7800), nil)

  assert(tracker:getBrokerCount() == 1, "broker tracked via consumer")
  local ttd = tracker:getTtd("broker-A")
  assert(ttd ~= nil, "TTD available via consumer pattern")
end)

-- ============================================================
-- Test group 14: Multiple Resource Types per Broker
-- ============================================================

test("broker with power and items via mixed telemetry/inject", function()
  setTime(1000)
  local tracker = TtdTracker.new({ minSamplesForRate = 3 })
  trackProgress = nil

  -- Power from telemetry
  tracker:onTelemetry(makePayload("broker-A", 8000))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7900))
  advance(10)
  tracker:onTelemetry(makePayload("broker-A", 7800))

  -- Items from injectSample
  tracker:injectSample("broker-A", "item", 1000, 1020)
  advance(10)
  tracker:injectSample("broker-A", "item", 800, 1030)
  advance(10)
  tracker:injectSample("broker-A", "item", 600, 1040)

  local ttd = tracker:getTtd("broker-A")
  assert(ttd.power ~= nil, "power resource exists")
  assert(ttd.item ~= nil, "item resource exists")
  assert(ttd.power.rateValid == true, "power rate valid")
  assert(ttd.item.rateValid == true, "item rate valid")
end)

-- ============================================================
-- Summary
-- ============================================================

io.write(string.format("\n=== TtdTracker Test Summary ===\n"))
io.write(string.format("  Run:   %d\n", testsRun))
io.write(string.format("  Pass:  %d\n", testsPassed))
io.write(string.format("  Fail:  %d\n", testsFailed))

if testsFailed > 0 then
  io.write("  RESULT: SOME TESTS FAILED\n")
  os.exit(1)
else
  io.write("  RESULT: ALL TESTS PASSED\n")
  os.exit(0)
end
