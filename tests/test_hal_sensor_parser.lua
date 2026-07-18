local Assert = require("tests.helpers.assertions")
local MockEnv = require("tests.helpers.mock_env")

MockEnv.setup()
package.preload["component"] = package.preload["component"] or function()
  return _G.component
end

local HAL = require("src.hal")
local MaintenanceReport = require("src.maintenance_report")

Assert.startTest("HAL:parseSensorData recognizes GT maintenance signals")
do
  local hal = HAL:new()
  local parsed, warning = hal:parseSensorData({
    "Shut down due to power loss",
    "Maintenance issues detected",
    "Has Problems",
    "Incomplete Structure",
  })

  Assert.isTrue(parsed.powerLossShutdown, "power-loss signal is recognized")
  Assert.isTrue(parsed.needsMaintenance, "maintenance signal is recognized")
  Assert.isTrue(parsed.hasProblems, "problem signal is recognized")
  Assert.isTrue(parsed.incompleteStructure, "structure signal is recognized")
  Assert.equal(4, parsed.issueCount, "each sensor signal is counted")
  Assert.isNil(warning, "valid sensor data has no warning")
end
Assert.endTest()

Assert.startTest("HAL:parseSensorData treats malformed data as advisory")
do
  local hal = HAL:new()
  local ok, parsed, warning = pcall(hal.parseSensorData, hal, "not sensor lines")

  Assert.isTrue(ok, "malformed sensor data never raises")
  Assert.equal(0, parsed.issueCount, "malformed data yields no sensor faults")
  Assert.match("expected a table", warning, "malformed data returns an advisory warning")

  local report = MaintenanceReport.new("sensor-test")
  report:reportAdvisory(HAL.FAULT_SENSOR_PARSE, warning)
  Assert.equal(0, report.faultCode, "an advisory does not set a blocking fault")
  Assert.equal(1, #report:getHistory(), "an advisory is retained in canonical history")
end
Assert.endTest()

Assert.startTest("HAL:requestCraft queries a matching craftable and requests its deficit")
do
  local requestedAmount = nil
  local hal = HAL:new()
  hal._proxyCache["me-controller"] = {
    timestamp = os.time(),
    proxy = {
      getCraftables = function(filter)
        if filter.name == "minecraft:iron_ingot" then
          return {
            {
              request = function(amount)
                requestedAmount = amount
                return { id = "crafting-job" }
              end,
            },
          }
        end
        return {}
      end,
    },
  }

  local ok, job = hal:requestCraft("me-controller", { name = "minecraft:iron_ingot" }, 32)
  Assert.isTrue(ok, "a matching craftable accepts a request")
  Assert.equal(32, requestedAmount, "the helper forwards only the missing amount")
  Assert.equal("crafting-job", job.id, "the crafting job is returned to the caller")
end
Assert.endTest()

if arg and arg[0] and arg[0]:match("test_hal_sensor_parser%.lua$") then
  os.exit(Assert.summary() and 0 or 1)
end

return true
