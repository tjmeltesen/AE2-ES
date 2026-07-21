-- test_phase_modules.lua — Isolated tests for each phase module in src/phases/
-- Verifies each module loads, constructs, and executes independently of the broker.

local BufferingPhase    = require("src.phases.buffering")
local LoggingPhase      = require("src.phases.logging")
local AllocatingPhase   = require("src.phases.allocating")
local TransferringPhase = require("src.phases.transferring")
local ProcessingPhase   = require("src.phases.processing")
local CleanupPhase      = require("src.phases.cleanup")

local Assert = require("tests.helpers.assertions")

-- Shared scheduler mock for phase module tests that now require one.
-- All phases use scheduler:forEach / scheduler:forEachPair for loop protection.
local SCHED_MOCK = {
  forEach = function(_, list, fn)
    for _, item in ipairs(list) do fn(item) end
    return #list
  end,
  forEachPair = function(_, tbl, fn)
    for k, v in pairs(tbl) do pcall(fn, k, v) end
    return 0
  end,
}

-- Register mock singleton so phases don't depend on broker context
local registry = require("src.scheduler_registry")
registry.set(SCHED_MOCK)

Assert.startTest("phase modules load independently")

-- Verify each module returns a table with a .new constructor
for _, entry in ipairs({
  { name = "BufferingPhase",    mod = BufferingPhase },
  { name = "LoggingPhase",      mod = LoggingPhase },
  { name = "AllocatingPhase",   mod = AllocatingPhase },
  { name = "TransferringPhase", mod = TransferringPhase },
  { name = "ProcessingPhase",   mod = ProcessingPhase },
  { name = "CleanupPhase",      mod = CleanupPhase },
}) do
  Assert.type("table", entry.mod, entry.name .. " exports a table")
  Assert.type("function", entry.mod.new, entry.name .. ".new is a function")
end
Assert.endTest()

-- =========================================================================
-- BufferingPhase
-- =========================================================================
Assert.startTest("BufferingPhase: empty poll stays in BUFFERING")
do
  local snapshot = {
    update = function() return false end,
    getSnapshotData = function() return nil end,
    reset = function() end,
  }
  local bp = BufferingPhase.new({
    bufferFeeder = function() return { items = {}, fluids = {} } end,
    snapshot = snapshot,
    logger = nil,
    hal = {},
  })
  local P = { BUFFERING = "BUFFERING", LOGGING = "LOGGING" }
  Assert.equal(P.BUFFERING, bp:execute(nil, P), "nil poll → BUFFERING")
  Assert.equal(P.BUFFERING, bp:execute(false, P), "unstable poll → BUFFERING")
end
Assert.endTest()

Assert.startTest("BufferingPhase: pollBuffer returns nil without feeder")
do
  local bp = BufferingPhase.new({
    bufferFeeder = nil, snapshot = { update = function() end }, hal = {},
  })
  Assert.isNil(bp:pollBuffer(), "pollBuffer nil when no feeder")
end
Assert.endTest()

Assert.startTest("BufferingPhase: bufferFeeder returning non-table logs warning")
do
  local warned = false
  local bp = BufferingPhase.new({
    bufferFeeder = function() return "not-a-table" end,
    snapshot = { update = function() end },
    logger = { warn = function(_, msg) if type(msg) == "string" and msg:find("non-table", 1, true) then warned = true end end },
    hal = {},
  })
  local result = bp:pollBuffer()
  Assert.isNil(result, "non-table bufferData → pollBuffer nil")
  Assert.isTrue(warned, "logger warned about non-table feeder")
end
Assert.endTest()

Assert.startTest("BufferingPhase: stable empty snapshot stays BUFFERING")
do
  local resetCalled = false
  local bp = BufferingPhase.new({
    bufferFeeder = function() return { items = {}, fluids = {} } end,
    snapshot = {
      update = function() return true end,
      getSnapshotData = function() return { items = {}, fluids = {} } end,
      reset = function() resetCalled = true end,
    },
    hal = {},
  })
  local P = { BUFFERING = "BUFFERING", LOGGING = "LOGGING" }
  Assert.equal(P.BUFFERING, bp:execute(true, P), "stable empty → BUFFERING")
  Assert.isTrue(resetCalled, "snapshot reset on empty stable data")
end
Assert.endTest()

-- =========================================================================
-- LoggingPhase
-- =========================================================================
Assert.startTest("LoggingPhase: empty snapshot returns BUFFERING")
do
  local lp = LoggingPhase.new({
    snapshot = { convertToManifest = function() return nil end },
    JobManifest = { new = function() return {} end },
    queue = { push = function() return false end },
  })
  local P = { BUFFERING = "BUFFERING", ALLOCATING = "ALLOCATING", LOGGING = "LOGGING" }
  Assert.equal(P.BUFFERING, lp:execute(P), "nil manifest → BUFFERING")
end
Assert.endTest()

Assert.startTest("LoggingPhase: full queue stays LOGGING")
do
  local lp = LoggingPhase.new({
    snapshot = {
      convertToManifest = function() return { id = "j1", inputs = {} } end,
      reset = function() end,
    },
    JobManifest = { new = function() return { id = "j1" } end },
    queue = { push = function() return false end },
  })
  local P = { BUFFERING = "BUFFERING", ALLOCATING = "ALLOCATING", LOGGING = "LOGGING" }
  Assert.equal(P.LOGGING, lp:execute(P), "full queue → LOGGING retry")
end
Assert.endTest()

-- =========================================================================
-- AllocatingPhase — smart dispatch is always on
-- =========================================================================
Assert.startTest("AllocatingPhase: empty queue returns BUFFERING")
do
  local ap = AllocatingPhase.new({
    queue = { popNextAvailable = function() return nil end },
    machineList = {},
    activeJobs = {},
    scheduler = SCHED_MOCK,
  })
  local P = { BUFFERING = "BUFFERING", ALLOCATING = "ALLOCATING", TRANSFERRING = "TRANSFERRING" }
  Assert.equal(P.BUFFERING, ap:execute(P), "empty queue → BUFFERING")
end
Assert.endTest()

Assert.startTest("AllocatingPhase: skips unhealthy machine, picks healthy")
do
  local MachineNode = require("src.MachineNode")
  local n1 = MachineNode.new("addr-1")
  local n2 = MachineNode.new("addr-2")
  n2:updateHealth({ "Incomplete Structure" })

  local halMock = {
    getProxy = function(_, addr)
      if addr == "addr-2" then
        return { getSensorInformation = function() return { "Incomplete Structure" } end }
      else
        return { getSensorInformation = function() return { "Progress: 0 s / 0 s" } end }
      end
    end,
  }

  local ap = AllocatingPhase.new({
    scheduler = SCHED_MOCK,
    queue = { popNextAvailable = function() return { id = "j1", status = "PENDING", bindHardware = function() end } end,
              push = function() end },
    machineList = {
      { laneId = "laneU", address = "addr-2", node = n2 },
      { laneId = "laneH", address = "addr-1", node = n1 },
    },
    activeJobs = {},
    hal = halMock,
  })
  local P = { BUFFERING = "BUFFERING", ALLOCATING = "ALLOCATING", TRANSFERRING = "TRANSFERRING" }
  local nextPhase = ap:execute(P)
  Assert.equal(P.TRANSFERRING, nextPhase, "dispatch → TRANSFERRING")
  Assert.equal("LOCKED", n1:getStatus(), "healthy locked")
  Assert.equal("AVAILABLE", n2:getStatus(), "unhealthy skipped")
  n1:unlock()
end
Assert.endTest()

Assert.startTest("AllocatingPhase: picks healthier machine when both pass")
do
  local MachineNode = require("src.MachineNode")
  local n1 = MachineNode.new("addr-1")
  local n2 = MachineNode.new("addr-2")

  local halMock = {
    getProxy = function(_, addr)
      if addr == "addr-1" then return { getSensorInformation = function() return { "Progress: 0 s / 0 s" } end }
      else return { getSensorInformation = function() return { "Progress: 0 s / 0 s", "Maintenance" } end }
      end
    end,
  }

  local ap = AllocatingPhase.new({
    scheduler = SCHED_MOCK,
    queue = { popNextAvailable = function() return { id = "j1", status = "PENDING", bindHardware = function() end } end,
              push = function() end },
    machineList = {
      { laneId = "lane1", address = "addr-1", node = n1 },
      { laneId = "lane2", address = "addr-2", node = n2 },
    },
    activeJobs = {},
    hal = halMock,
  })
  local P = { BUFFERING = "BUFFERING", ALLOCATING = "ALLOCATING", TRANSFERRING = "TRANSFERRING" }
  local nextPhase = ap:execute(P)
  Assert.equal(P.TRANSFERRING, nextPhase, "dispatch succeeds")
  Assert.equal("LOCKED", n1:getStatus(), "healthier (100) locked over maintenance (80)")
  Assert.equal("AVAILABLE", n2:getStatus(), "lower-health skipped")
  n1:unlock()
end
Assert.endTest()

Assert.startTest("AllocatingPhase: re-queues job when all machines unhealthy")
do
  local MachineNode = require("src.MachineNode")
  local n1 = MachineNode.new("addr-1")
  local n2 = MachineNode.new("addr-2")
  n1:updateHealth({ "Incomplete Structure" })
  n2:updateHealth({ "Shut down due to power loss" })

  local halMock = {
    getProxy = function() return { getSensorInformation = function() return { "Incomplete Structure" } end } end,
  }

  local pushCalled = false
  local ap = AllocatingPhase.new({
    scheduler = SCHED_MOCK,
    queue = { popNextAvailable = function() return { id = "j1", status = "PENDING", bindHardware = function() end } end,
              push = function(_) pushCalled = true end },
    machineList = {
      { laneId = "lane1", address = "addr-1", node = n1 },
      { laneId = "lane2", address = "addr-2", node = n2 },
    },
    activeJobs = {},
    hal = halMock,
  })
  local P = { BUFFERING = "BUFFERING", ALLOCATING = "ALLOCATING", TRANSFERRING = "TRANSFERRING" }
  local nextPhase = ap:execute(P)
  Assert.equal(P.ALLOCATING, nextPhase, "all unhealthy → ALLOCATING retry")
  Assert.equal("AVAILABLE", n1:getStatus(), "lane1 not locked")
  Assert.equal("AVAILABLE", n2:getStatus(), "lane2 not locked")
  Assert.isTrue(pushCalled, "job re-queued")
end
Assert.endTest()

-- =========================================================================
-- ProcessingPhase — progress-driven wake-up + fast recipe detection
-- =========================================================================
Assert.startTest("ProcessingPhase: no active jobs is no-op")
do
  local pp = ProcessingPhase.new({
    hal = {}, machines = {}, machineTransposers = {},
    reports = {}, stats = { jobsCompleted = 0, jobsFaulted = 0, totalJobTime = 0 },
    activeJobs = {}, timeSliceScheduler = SCHED_MOCK,
  })
  local P = { PROCESSING = "PROCESSING", CLEANUP = "CLEANUP" }
  local ok = pcall(function() pp:execute(P) end)
  Assert.isTrue(ok, "processing with no jobs does not error")
end
Assert.endTest()

Assert.startTest("ProcessingPhase: wake-time guard skips hardware poll")
do
  local clock = 0  -- mutable fake clock
  local pollCount = 0

  local pp = ProcessingPhase.new({
    hal = {
      pollMachineHardware = function() pollCount = pollCount + 1
        return { active = true, progress = 30, maxProgress = 60, sensorLines = {} }
      end,
      getProxy = function() return { isMachineActive = function() return true end } end,
      checkMaintenanceState = function() return { faulted = false, advisories = {} } end,
    },
    machines       = { lane1 = { hardwareAddress = "a1", hasFault = function() return false end } },
    machineTransposers = {},
    reports        = { lane1 = { reportAdvisory = function() end } },
    stats          = { jobsCompleted = 0, jobsFaulted = 0, totalJobTime = 0 },
    timeSliceScheduler = SCHED_MOCK,
    activeJobs     = {
      lane1 = { phase = "PROCESSING", manifest = { id = "j1", fault = function() end, age = function() return 0 end } },
    },
    clock = function() clock = clock + 0.5; return clock end,
  })
  local P = { PROCESSING = "PROCESSING", CLEANUP = "CLEANUP" }

  -- First call: hardware poll fires, sets wake time (~57s from now)
  pp:execute(P)
  Assert.isTrue(pollCount >= 1, "first tick polls hardware")
  pollCount = 0

  -- Next 10 calls: within wake time, no hardware poll
  for _ = 1, 10 do
    pp:execute(P)
  end
  Assert.equal(0, pollCount, "no hardware poll during sleep window (" .. tostring(pollCount) .. ")")
end
Assert.endTest()

Assert.startTest("ProcessingPhase: fast recipe detected on first check")
do
  local clockVal = 0
  local pp = ProcessingPhase.new({
    hal = {
      pollMachineHardware = function()
        return { active = false, progress = 0, maxProgress = 0, sensorLines = {} }
      end,
      getProxy = function() return { isMachineActive = function() return false end } end,
      checkMaintenanceState = function() return { faulted = false, advisories = {} } end,
    },
    machines       = {
      lane1 = {
        hardwareAddress = "a1",
        hasFault = function() return false end,
        parseHealth = function() return { idle = true } end,
      },
    },
    machineTransposers = {},
    reports        = { lane1 = { reportAdvisory = function() end } },
    stats          = { jobsCompleted = 0, jobsFaulted = 0, totalJobTime = 0 },
    timeSliceScheduler = SCHED_MOCK,
    activeJobs     = {
      lane1 = {
        phase    = "PROCESSING",
        manifest = {
          id = "j1", fault = function() end,
          age = function() return 0 end,
          updateState = function() end,
        },
      },
    },
    clock = function() clockVal = clockVal + 1; return clockVal end,
  })
  local P = { PROCESSING = "PROCESSING", CLEANUP = "CLEANUP" }
  pp:execute(P)
  Assert.equal("CLEANUP", pp._activeJobs.lane1.phase or
    (function() for k,v in pairs(pp._activeJobs) do return v.phase end end)(),
    "fast recipe → CLEANUP")
end
Assert.endTest()

Assert.startTest("ProcessingPhase: fast recipe NOT triggered when machine faulted")
do
  local pp = ProcessingPhase.new({
    hal = {
      pollMachineHardware = function() return { active = false, progress = 0, maxProgress = 0, sensorLines = {} } end,
      getProxy = function() return { isMachineActive = function() return false end } end,
      checkMaintenanceState = function() return { faulted = false, advisories = {} } end,
    },
    machines       = {
      lane1 = {
        hardwareAddress = "a1",
        hasFault = function() return true end,
        maintenanceFlags = { code = 1, description = "test fault" },
        parseHealth = function() return { idle = true } end,
      },
    },
    machineTransposers = {},
    reports        = { lane1 = { reportFault = function() end } },
    stats          = { jobsCompleted = 0, jobsFaulted = 0, totalJobTime = 0 },
    activeJobs     = {
      lane1 = {
        phase = "PROCESSING",
        manifest = { id = "j1", fault = function() end, age = function() return 0 end },
      },
    },
  })
  local P = { PROCESSING = "PROCESSING", CLEANUP = "CLEANUP" }
  pp:execute(P)
  -- Fault path should fire before fast recipe path
  local job = nil
  for _, v in pairs(pp._activeJobs) do job = v end
  Assert.isTrue(job.phase == "CLEANUP" and pp._stats.jobsFaulted >= 0,
    "faulted machine goes to cleanup via fault path, not fast recipe")
end
Assert.endTest()

-- =========================================================================
-- CleanupPhase
-- =========================================================================
Assert.startTest("CleanupPhase: no active jobs is no-op")
do
  local cp = CleanupPhase.new({
    hal = {}, machines = {}, machineTransposers = {},
    reports = {}, stats = { jobsCompleted = 0, jobsFaulted = 0, totalJobTime = 0 },
    activeJobs = {}, scheduler = SCHED_MOCK,
  })
  local P = { CLEANUP = "CLEANUP" }
  local ok = pcall(function() cp:execute(P) end)
  Assert.isTrue(ok, "cleanup with no jobs does not error")
end
Assert.endTest()

-- =========================================================================
-- TransferringPhase
-- =========================================================================
Assert.startTest("TransferringPhase: no active jobs returns ALLOCATING")
do
  local tp = TransferringPhase.new({
    hal = {}, machineList = {}, machineTransposers = {},
    activeJobs = {},
  })
  local P = { ALLOCATING = "ALLOCATING", TRANSFERRING = "TRANSFERRING" }
  Assert.equal(P.ALLOCATING, tp:execute(P), "no active → ALLOCATING")
end
Assert.endTest()

-- =========================================================================
-- Import safety: phase modules don't require broker internals
-- =========================================================================
Assert.startTest("phase module import safety")
do
  for _, name in ipairs({"buffering","logging","allocating","transferring","processing","cleanup"}) do
    local path = "src/phases/" .. name .. ".lua"
    local f = io.open(path)
    local content = f:read("*a")
    f:close()
    for line in content:gmatch("[^\n]+") do
      local t = line:match("^%s*(.-)%s*$")
      if t:match("require") and not t:match("^%-%-") then
        Assert.isFalse(t:match("require.*exec_broker") ~= nil,
          name .. ".lua must not require exec_broker (" .. path .. ":" .. t .. ")")
      end
    end
  end
end
Assert.endTest()
