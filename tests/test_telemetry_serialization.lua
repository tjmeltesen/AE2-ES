-- test_telemetry_serialization.lua
-- Phase A: Assert TelemetryPayload serialization valid.
-- Tests build, serialize, deserialize round-trips, and field validation.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

local TelemetryPayload = require("src.telemetrypayload")

-- ============================================================
-- Test Group 1: Payload Construction
-- ============================================================

-- Test 1.1: Build creates valid payload with all fields
Assert.startTest("build creates valid payload with all required fields")
do
  local payload, err = TelemetryPayload.build({
    brokerId = "broker-alpha",
    queueLength = 3,
    hardwareMatrix = {
      {address = "mach-1", status = "PROCESSING"},
      {address = "mach-2", status = "AVAILABLE"},
    },
    alerts = {
      {code = "LOW_POWER", severity = "WARN"},
    },
  })

  Assert.notNil(payload, "Payload should be created: " .. tostring(err))
  Assert.equal("broker-alpha", payload.brokerId, "brokerId should match")
  Assert.equal(1, payload.schemaVersion, "schemaVersion should be 1")
  Assert.type("number", payload.timestamp, "timestamp should be a number")
  Assert.equal(3, payload.queueLength, "queueLength should be 3")
  Assert.type("table", payload.hardwareMatrix, "hardwareMatrix should be a table")
  Assert.type("table", payload.alerts, "alerts should be a table")
end
Assert.endTest()

-- Test 1.2: Build defaults for optional fields
Assert.startTest("build applies defaults for optional fields")
do
  local payload, err = TelemetryPayload.build({ brokerId = "broker-beta" })
  Assert.notNil(payload, "Payload should be created with defaults")
  Assert.equal(0, payload.queueLength, "queueLength should default to 0")
  Assert.tableEmpty(payload.hardwareMatrix, "hardwareMatrix should default to empty")
  Assert.tableEmpty(payload.alerts, "alerts should default to empty")
  Assert.type("number", payload.timestamp, "timestamp should be auto-set")
end
Assert.endTest()

-- Test 1.3: Build rejects missing brokerId
Assert.startTest("build rejects missing brokerId")
do
  local payload, err = TelemetryPayload.build({ queueLength = 5 })
  Assert.isNil(payload, "Payload should be nil without brokerId")
  Assert.notNil(err, "Error should be returned")
  Assert.match("brokerId", err, "Error should mention brokerId")
end
Assert.endTest()

-- Test 1.4: Build rejects nil params
Assert.startTest("build rejects nil params")
do
  local payload, err = TelemetryPayload.build(nil)
  Assert.isNil(payload, "Payload should be nil")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 1.5: Build validates field types
Assert.startTest("build validates field types")
do
  -- Wrong type for queueLength
  local p1, e1 = TelemetryPayload.build({
    brokerId = "test",
    queueLength = "not_a_number",
  })
  Assert.isNil(p1, "Should reject string queueLength")
  Assert.match("queueLength", e1, "Error should mention queueLength")

  -- Wrong type for hardwareMatrix
  local p2, e2 = TelemetryPayload.build({
    brokerId = "test",
    hardwareMatrix = "not_a_table",
  })
  Assert.isNil(p2, "Should reject string hardwareMatrix")
  Assert.match("hardwareMatrix", e2, "Error should mention hardwareMatrix")
end
Assert.endTest()

-- ============================================================
-- Test Group 2: Serialization
-- ============================================================

-- Test 2.1: serialize produces non-empty string
Assert.startTest("serialize produces non-empty string")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-serial",
    queueLength = 7,
  })
  local serialized = payload:serialize()
  Assert.notNil(serialized, "Serialized output should not be nil")
  Assert.type("string", serialized, "Serialized output should be a string")
  Assert.greaterThan(0, #serialized, "Serialized string should not be empty")
end
Assert.endTest()

-- Test 2.2: Serialized output contains key fields
Assert.startTest("serialized output contains key fields")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-gamma",
    queueLength = 12,
    hardwareMatrix = {{address = "m1", status = "AVAILABLE"}},
    alerts = {{code = "TEST", severity = "INFO"}},
  })
  local s = payload:serialize()
  Assert.match("broker%-gamma", s, "Should contain brokerId")
  Assert.match("queueLength", s, "Should contain queueLength key")
  Assert.match("hardwareMatrix", s, "Should contain hardwareMatrix key")
  Assert.match("alerts", s, "Should contain alerts key")
end
Assert.endTest()

-- Test 2.3: serialize produces valid Lua that can be loaded
Assert.startTest("serialize produces valid Lua syntax")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-delta",
    queueLength = 1,
  })
  local s = payload:serialize()
  local f, err = (loadstring or load)("return " .. s)
  Assert.notNil(f, "Serialized string should be valid Lua: " .. tostring(err))
end
Assert.endTest()

-- Test 2.4: Serialize handles empty hardwareMatrix and alerts
Assert.startTest("serialize handles empty collections")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-empty",
  })
  local s = payload:serialize()
  Assert.notNil(s, "Should serialize with empty collections")
  Assert.greaterThan(0, #s, "Should produce non-empty string")
end
Assert.endTest()

-- Test 2.5: Serialize preserves all data types
Assert.startTest("serialize preserves numbers, strings, booleans, tables")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-types",
    queueLength = 42,
    hardwareMatrix = {
      {address = "hw-1", status = "PROCESSING", progress = 0.75},
      {address = "hw-2", status = "AVAILABLE", active = true},
    },
    alerts = {
      {code = "OVERHEAT", severity = "CRITICAL", active = true, temp = 3500},
    },
  })
  local s = payload:serialize()
  Assert.match("42", s, "Should contain number 42")
  Assert.match("0%.75", s, "Should contain float 0.75")
  Assert.match("true", s, "Should contain boolean true")
  Assert.match("OVERHEAT", s, "Should contain string OVERHEAT")
end
Assert.endTest()

-- ============================================================
-- Test Group 3: Deserialization
-- ============================================================

-- Test 3.1: Round-trip serialize → deserialize preserves data
Assert.startTest("round-trip serialize/deserialize preserves all fields")
do
  local original, _ = TelemetryPayload.build({
    brokerId = "broker-roundtrip",
    queueLength = 5,
    hardwareMatrix = {
      {address = "hw-a", status = "AVAILABLE"},
      {address = "hw-b", status = "PROCESSING"},
    },
    alerts = {
      {code = "WARNING_LOW_ITEM", severity = "WARN"},
    },
    timestamp = 1700000000,
  })

  local serialized = original:serialize()
  local restored, err = TelemetryPayload.deserialize(serialized)

  Assert.notNil(restored, "Deserialization should succeed: " .. tostring(err))
  Assert.equal(original.brokerId, restored.brokerId, "brokerId should survive round-trip")
  Assert.equal(original.queueLength, restored.queueLength, "queueLength should survive round-trip")
  Assert.equal(original.timestamp, restored.timestamp, "timestamp should survive round-trip")
  Assert.equal(#original.hardwareMatrix, #restored.hardwareMatrix, "hardwareMatrix count should match")
  Assert.equal(#original.alerts, #restored.alerts, "alert count should match")
end
Assert.endTest()

-- Test 3.2: deserialize validates required fields
Assert.startTest("deserialize validates required fields")
do
  -- Missing queueLength
  local partialData = "{brokerId=\"test\",timestamp=1,hardwareMatrix={},alerts={}}"
  local payload, err = TelemetryPayload.deserialize(partialData)
  Assert.isNil(payload, "Should reject missing queueLength")
  Assert.match("queueLength", err, "Error should mention queueLength")

  -- Missing hardwareMatrix
  local partialData2 = "{brokerId=\"test\",timestamp=1,queueLength=0,alerts={}}"
  local payload2, err2 = TelemetryPayload.deserialize(partialData2)
  Assert.isNil(payload2, "Should reject missing hardwareMatrix")
  Assert.match("hardwareMatrix", err2, "Error should mention hardwareMatrix")
end
Assert.endTest()

-- Test 3.3: Deserialize preserves nested table structures
Assert.startTest("deserialize preserves nested table structures")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-nested",
    queueLength = 2,
    hardwareMatrix = {
      {address = "nested-1", status = "PROCESSING", details = {progress = 50, eta = 120}},
    },
    alerts = {
      {code = "NESTED", data = {key = "value", nested = {deep = true}}},
    },
  })
  local s = payload:serialize()
  local restored, _ = TelemetryPayload.deserialize(s)

  Assert.notNil(restored)
  Assert.notNil(restored.hardwareMatrix[1].details, "Nested table in hardwareMatrix should survive")
  Assert.equal(50, restored.hardwareMatrix[1].details.progress, "Nested number should survive")
  Assert.notNil(restored.alerts[1].data.nested, "Deeply nested data should survive")
  Assert.isTrue(restored.alerts[1].data.nested.deep, "Deep bool should survive")
end
Assert.endTest()

-- ============================================================
-- Test Group 4: Serialization Edge Cases
-- ============================================================

-- Test 4.1: Serialize handles special characters in brokerId
Assert.startTest("serialize handles special characters in brokerId")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-with spaces_and-dashes",
    queueLength = 0,
  })
  local s = payload:serialize()
  Assert.notNil(s, "Should serialize with special chars")
  local restored, _ = TelemetryPayload.deserialize(s)
  Assert.equal("broker-with spaces_and-dashes", restored.brokerId,
    "Special chars should survive round-trip")
end
Assert.endTest()

-- Test 4.2: Serialize handles large hardware matrix
Assert.startTest("serialize handles large hardware matrix")
do
  local matrix = {}
  for i = 1, 50 do
    table.insert(matrix, {
      address = "machine-" .. i,
      status = "AVAILABLE",
      progress = math.random(0, 100),
    })
  end
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-large",
    queueLength = 20,
    hardwareMatrix = matrix,
  })
  local s = payload:serialize()
  Assert.notNil(s, "Should serialize large payload")
  local restored, _ = TelemetryPayload.deserialize(s)
  Assert.equal(50, #restored.hardwareMatrix, "All 50 machines should survive")
end
Assert.endTest()

-- Test 4.3: Payload validation passes for well-formed payloads
Assert.startTest("validate passes for well-formed payload")
do
  local ok, err = TelemetryPayload.validate({
    brokerId = "v-test",
    timestamp = 1234567890,
    queueLength = 10,
    hardwareMatrix = {},
    alerts = {},
  })
  Assert.isTrue(ok, "Valid payload should pass validation: " .. tostring(err))
end
Assert.endTest()

-- Test 4.4: Payload validation catches missing fields
Assert.startTest("validate catches missing fields")
do
  local ok, err = TelemetryPayload.validate({ brokerId = "test" })
  Assert.isFalse(ok, "Should fail with missing fields")
  Assert.notNil(err, "Should return error message")
end
Assert.endTest()

-- Test 4.5: Payload validation catches wrong types
Assert.startTest("validate catches wrong types")
do
  local ok, err = TelemetryPayload.validate({
    brokerId = 123,           -- should be string
    timestamp = 1234567890,
    queueLength = "ten",      -- should be number
    hardwareMatrix = {},
    alerts = {},
  })
  Assert.isFalse(ok, "Should fail with wrong types")
  Assert.notNil(err, "Should return error message")
end
Assert.endTest()

-- ============================================================
-- Test Group 5: Transmit behavior
-- ============================================================

-- Test 5.1: transmit succeeds with valid payload
Assert.startTest("transmit succeeds with valid payload")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-tx",
    queueLength = 1,
  })
  local ok = payload:transmit("target-address", 123)
  Assert.isTrue(ok, "Transmit should succeed")
end
Assert.endTest()

-- Test 5.2: transmit fails with missing address
Assert.startTest("transmit fails with missing modem address")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-tx-fail",
  })
  local ok = payload:transmit(nil, 123)
  Assert.isFalse(ok, "Transmit should fail without address")
end
Assert.endTest()

-- Test 5.3: hasAlert detects present alerts
Assert.startTest("hasAlert detects present and missing alerts")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "broker-alerts",
    queueLength = 1,
    alerts = {
      {code = "LOW_ITEM", severity = "WARN"},
      {code = "MACHINE_FAULT", severity = "CRITICAL"},
    },
  })
  Assert.isTrue(payload:hasAlert("LOW_ITEM"), "Should find LOW_ITEM alert")
  Assert.isTrue(payload:hasAlert("MACHINE_FAULT"), "Should find MACHINE_FAULT alert")
  Assert.isFalse(payload:hasAlert("NONEXISTENT"), "Should not find nonexistent alert")
end
Assert.endTest()

-- Test 5.4: Schema version is consistent
Assert.startTest("schema version is consistent")
do
  local p1, _ = TelemetryPayload.build({ brokerId = "a" })
  local p2, _ = TelemetryPayload.build({ brokerId = "b" })
  Assert.equal(p1.schemaVersion, p2.schemaVersion, "All payloads should have same schema version")
  Assert.equal(1, p1.schemaVersion, "Schema version should be 1")
end
Assert.endTest()
