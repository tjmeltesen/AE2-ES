-- test_malformed_payload.lua
-- Phase A: Malformed payload handling.
-- Tests that deserialize gracefully handles invalid, truncated, and
-- malicious input without crashing the Exec Broker or Supervisor.

local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")
MockEnv.setup()

local TelemetryPayload = require("src.telemetrypayload")

-- ============================================================
-- Test Group 1: Nil and Empty Input
-- ============================================================

-- Test 1.1: deserialize handles nil input
Assert.startTest("deserialize handles nil input")
do
  local payload, err = TelemetryPayload.deserialize(nil)
  Assert.isNil(payload, "Payload should be nil for nil input")
  Assert.notNil(err, "Error should be returned for nil input")
end
Assert.endTest()

-- Test 1.2: deserialize handles empty string
Assert.startTest("deserialize handles empty string")
do
  local payload, err = TelemetryPayload.deserialize("")
  Assert.isNil(payload, "Payload should be nil for empty string")
  Assert.notNil(err, "Error should be returned for empty string")
end
Assert.endTest()

-- Test 1.3: deserialize handles whitespace string
Assert.startTest("deserialize handles whitespace-only string")
do
  local payload, err = TelemetryPayload.deserialize("   ")
  Assert.isNil(payload, "Payload should be nil for whitespace string")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- ============================================================
-- Test Group 2: Invalid Lua Syntax
-- ============================================================

-- Test 2.1: deserialize handles garbage text
Assert.startTest("deserialize handles garbage text")
do
  local garbage = "this is not lua syntax at all!!!"
  local payload, err = TelemetryPayload.deserialize(garbage)
  Assert.isNil(payload, "Payload should be nil for garbage input")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 2.2: deserialize handles malformed table syntax
Assert.startTest("deserialize handles malformed table syntax")
do
  local badTable = "{brokerId=\"test\", queueLength=,}"
  local payload, err = TelemetryPayload.deserialize(badTable)
  Assert.isNil(payload, "Payload should be nil for malformed table")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 2.3: deserialize handles unclosed brackets
Assert.startTest("deserialize handles unclosed brackets")
do
  local unclosed = "{brokerId=\"test\", queueLength=5"
  local payload, err = TelemetryPayload.deserialize(unclosed)
  Assert.isNil(payload, "Payload should be nil for unclosed brackets")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 2.4: deserialize handles mismatched brackets
Assert.startTest("deserialize handles mismatched brackets")
do
  local mismatched = "{brokerId=\"test\", queueLength=5]]"
  local payload, err = TelemetryPayload.deserialize(mismatched)
  Assert.isNil(payload, "Payload should be nil for mismatched brackets")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 2.5: deserialize handles invalid escape sequences
Assert.startTest("deserialize handles invalid escape sequences")
do
  local badEscape = "{brokerId=\"test\\x\",queueLength=0,hardwareMatrix={},alerts={},timestamp=1}"
  -- Some Lua versions may reject, others may accept — we just need no crash
  local ok = pcall(function()
    TelemetryPayload.deserialize(badEscape)
  end)
  Assert.isTrue(ok, "Should not crash on invalid escape sequence")
end
Assert.endTest()

-- ============================================================
-- Test Group 3: Non-Table Deserialized Data
-- ============================================================

-- Test 3.1: deserialize handles number literal input
Assert.startTest("deserialize handles number literal")
do
  local payload, err = TelemetryPayload.deserialize("42")
  Assert.isNil(payload, "Payload should be nil for plain number")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 3.2: deserialize handles string literal input
Assert.startTest("deserialize handles string literal")
do
  local payload, err = TelemetryPayload.deserialize("\"hello\"")
  Assert.isNil(payload, "Payload should be nil for plain string")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 3.3: deserialize handles boolean literal input
Assert.startTest("deserialize handles boolean literal")
do
  local payload, err = TelemetryPayload.deserialize("true")
  Assert.isNil(payload, "Payload should be nil for plain boolean")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 3.4: deserialize handles nil literal input
Assert.startTest("deserialize handles nil literal")
do
  local payload, err = TelemetryPayload.deserialize("nil")
  Assert.isNil(payload, "Payload should be nil for literal nil")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- ============================================================
-- Test Group 4: Truncated and Partial Data
-- ============================================================

-- Test 4.1: deserialize handles truncated payload mid-string
Assert.startTest("deserialize handles truncated payload mid-string")
do
  -- Truncated right in the middle of brokerId value
  local truncated = "{brokerId=\"broker-alph"
  local payload, err = TelemetryPayload.deserialize(truncated)
  Assert.isNil(payload, "Payload should be nil for truncated data")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 4.2: deserialize handles truncated payload mid-table
Assert.startTest("deserialize handles truncated payload mid-table")
do
  local truncated = "{brokerId=\"test\", queueLength=5, hardwareMatrix={{addr"
  local payload, err = TelemetryPayload.deserialize(truncated)
  Assert.isNil(payload, "Payload should be nil for truncated table")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 4.3: deserialize handles truncated payload at key-value boundary
Assert.startTest("deserialize handles truncated at key-value boundary")
do
  local truncated = "{brokerId=\"test\", queueLength="
  local payload, err = TelemetryPayload.deserialize(truncated)
  Assert.isNil(payload, "Payload should be nil for truncated key-value")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 4.4: deserialize handles missing comma between fields
Assert.startTest("deserialize handles missing comma between fields")
do
  local badComma = "{brokerId=\"test\" queueLength=5,hardwareMatrix={},alerts={},timestamp=1}"
  local payload, err = TelemetryPayload.deserialize(badComma)
  Assert.isNil(payload, "Should reject missing commas")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- ============================================================
-- Test Group 5: Missing Required Fields
-- ============================================================

-- Test 5.1: deserialize rejects payload missing brokerId
Assert.startTest("deserialize rejects missing brokerId")
do
  local data = "{queueLength=5,hardwareMatrix={},alerts={},timestamp=1}"
  local payload, err = TelemetryPayload.deserialize(data)
  Assert.isNil(payload, "Should reject missing brokerId")
  Assert.match("brokerId", err)
end
Assert.endTest()

-- Test 5.2: deserialize rejects payload missing queueLength
Assert.startTest("deserialize rejects missing queueLength")
do
  local data = "{brokerId=\"test\",hardwareMatrix={},alerts={},timestamp=1}"
  local payload, err = TelemetryPayload.deserialize(data)
  Assert.isNil(payload, "Should reject missing queueLength")
  Assert.match("queueLength", err)
end
Assert.endTest()

-- Test 5.3: deserialize rejects payload missing hardwareMatrix
Assert.startTest("deserialize rejects missing hardwareMatrix")
do
  local data = "{brokerId=\"test\",queueLength=5,alerts={},timestamp=1}"
  local payload, err = TelemetryPayload.deserialize(data)
  Assert.isNil(payload, "Should reject missing hardwareMatrix")
  Assert.match("hardwareMatrix", err)
end
Assert.endTest()

-- Test 5.4: deserialize rejects payload missing alerts
Assert.startTest("deserialize rejects missing alerts")
do
  local data = "{brokerId=\"test\",queueLength=5,hardwareMatrix={},timestamp=1}"
  local payload, err = TelemetryPayload.deserialize(data)
  Assert.isNil(payload, "Should reject missing alerts")
  Assert.match("alerts", err)
end
Assert.endTest()

-- Test 5.5: deserialize rejects payload missing timestamp
Assert.startTest("deserialize rejects missing timestamp")
do
  local data = "{brokerId=\"test\",queueLength=5,hardwareMatrix={},alerts={}}"
  local payload, err = TelemetryPayload.deserialize(data)
  Assert.isNil(payload, "Should reject missing timestamp")
  Assert.match("timestamp", err)
end
Assert.endTest()

-- ============================================================
-- Test Group 6: Type Mismatches and Wrong Data Shapes
-- ============================================================

-- Test 6.1: Reject queueLength as string
Assert.startTest("reject queueLength as string")
do
  local payload, err = TelemetryPayload.build({
    brokerId = "test",
    queueLength = "five",
  })
  Assert.isNil(payload, "Should reject string queueLength")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- Test 6.2: Reject hardwareMatrix as string
Assert.startTest("reject hardwareMatrix as string")
do
  local payload, err = TelemetryPayload.build({
    brokerId = "test",
    hardwareMatrix = "not-a-table",
  })
  Assert.isNil(payload, "Should reject string hardwareMatrix")
end
Assert.endTest()

-- Test 6.3: Reject alerts as string
Assert.startTest("reject alerts as string")
do
  local payload, err = TelemetryPayload.build({
    brokerId = "test",
    alerts = "not-a-table",
  })
  Assert.isNil(payload, "Should reject string alerts")
end
Assert.endTest()

-- Test 6.4: Reject brokerId as number
Assert.startTest("reject brokerId as number")
do
  local payload, err = TelemetryPayload.build({
    brokerId = 12345,
  })
  Assert.isNil(payload, "Should reject numeric brokerId")
  Assert.notNil(err, "Error should be returned")
end
Assert.endTest()

-- ============================================================
-- Test Group 7: Malicious / Oversized Input
-- ============================================================

-- Test 7.1: Very long input does not crash
Assert.startTest("very long input does not crash")
do
  local longStr = "{brokerId=\"" .. string.rep("A", 10000) .. "\",queueLength=0,hardwareMatrix={},alerts={},timestamp=1}"
  local ok = pcall(function()
    TelemetryPayload.deserialize(longStr)
  end)
  Assert.isTrue(ok, "Should not crash on very long input string")
end
Assert.endTest()

-- Test 7.2: Very deeply nested input does not crash
Assert.startTest("deeply nested input does not crash")
do
  -- Build deep nested structure
  local function buildDeep(depth)
    if depth <= 0 then return "{}" end
    return "{inner=" .. buildDeep(depth - 1) .. "}"
  end
  local deepData = "{brokerId=\"test\",queueLength=0,hardwareMatrix=" ..
    buildDeep(30) .. ",alerts={},timestamp=1}"

  local ok = pcall(function()
    TelemetryPayload.deserialize(deepData)
  end)
  -- Deep nesting may fail due to Lua recursion limits, but must not crash
  Assert.isTrue(ok, "Should not crash on deeply nested input")
end
Assert.endTest()

-- Test 7.3: Binary/garbage bytes do not crash
Assert.startTest("binary garbage bytes do not crash")
do
  local binary = string.char(0, 1, 2, 127, 128, 255) .. "{brokerId=\"x\"}"
  local ok = pcall(function()
    TelemetryPayload.deserialize(binary)
  end)
  Assert.isTrue(ok, "Should not crash on binary garbage")
end
Assert.endTest()

-- Test 7.4: Null bytes in input do not crash
Assert.startTest("null bytes in input do not crash")
do
  local withNull = "{brokerId=\"test\0inject\",queueLength=0,hardwareMatrix={},alerts={},timestamp=1}"
  local ok = pcall(function()
    TelemetryPayload.deserialize(withNull)
  end)
  Assert.isTrue(ok, "Should not crash on null bytes")
end
Assert.endTest()

-- Test 7.5: Newlines and control characters do not crash
Assert.startTest("control characters do not crash")
do
  local withCtrl = "{brokerId=\"test\\n\\r\\t\",queueLength=0,hardwareMatrix={},alerts={},timestamp=1}"
  local ok = pcall(function()
    TelemetryPayload.deserialize(withCtrl)
  end)
  Assert.isTrue(ok, "Should not crash on control chars")
end
Assert.endTest()

-- ============================================================
-- Test Group 8: Extra / Unknown Fields Are Tolerated
-- ============================================================

-- Test 8.1: Extra unknown fields are silently ignored
Assert.startTest("extra unknown fields are tolerated")
do
  local payload, _ = TelemetryPayload.build({ brokerId = "test-extra" })
  local s = payload:serialize()

  -- Inject an extra field into the serialized form
  local modified = s:gsub("}$", ",extraField=\"should-be-ignored\"}")
  local restored, err = TelemetryPayload.deserialize(modified)

  Assert.notNil(restored, "Should deserialize with extra field: " .. tostring(err))
  Assert.equal("test-extra", restored.brokerId, "brokerId should survive")
end
Assert.endTest()

-- Test 8.2: Extra fields in nested tables are tolerated
Assert.startTest("extra fields in nested tables are tolerated")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "test-nested-extra",
    queueLength = 1,
    hardwareMatrix = {
      {address = "m1", status = "OK", extraField = "ignored"},
    },
  })
  local s = payload:serialize()
  local restored, _ = TelemetryPayload.deserialize(s)
  Assert.notNil(restored, "Should tolerate extra fields in nested tables")
end
Assert.endTest()

-- ============================================================
-- Test Group 9: Empty Collections
-- ============================================================

-- Test 9.1: Empty hardwareMatrix is valid
Assert.startTest("empty hardwareMatrix is valid")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "test-empty-hw",
    hardwareMatrix = {},
  })
  Assert.notNil(payload, "Should accept empty hardwareMatrix")
  Assert.tableEmpty(payload.hardwareMatrix, "hardwareMatrix should be empty")
end
Assert.endTest()

-- Test 9.2: Empty alerts is valid
Assert.startTest("empty alerts is valid")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "test-empty-alerts",
    alerts = {},
  })
  Assert.notNil(payload, "Should accept empty alerts")
  Assert.tableEmpty(payload.alerts, "alerts should be empty")
end
Assert.endTest()

-- Test 9.3: Empty collections survive round-trip
Assert.startTest("empty collections survive round-trip")
do
  local payload, _ = TelemetryPayload.build({
    brokerId = "test-empty-rt",
    queueLength = 0,
    hardwareMatrix = {},
    alerts = {},
  })
  local s = payload:serialize()
  local restored, _ = TelemetryPayload.deserialize(s)
  Assert.notNil(restored, "Empty payload should survive round-trip")
  Assert.tableEmpty(restored.hardwareMatrix, "hardwareMatrix should still be empty")
  Assert.tableEmpty(restored.alerts, "alerts should still be empty")
end
Assert.endTest()
