local Assert = require("tests.helpers.assertions")

package.path = "./lib/?.lua;./src/?.lua;" .. package.path

local StateMachine = require("lib.state_machine")
local MachineNode = require("src.MachineNode")

Assert.startTest("StateMachine: transitions invoke ordered hooks")
do
  local events = {}
  local data = { events = events }
  local machine = StateMachine.new("IDLE", data)
    :addState("IDLE", {
      exit = function(state, _, target)
        table.insert(state.events, "exit:IDLE:" .. target)
      end,
      update = function(_, context)
        return context.next
      end,
    })
    :addState("RUNNING", {
      enter = function(state, _, previous)
        table.insert(state.events, "enter:RUNNING:" .. previous)
      end,
      onUpdate = function()
        return "DONE"
      end,
    })
    :addState("DONE", {})

  Assert.equal("IDLE", machine:getState(), "Starts in initial state")
  Assert.equal("RUNNING", machine:update({ next = "RUNNING" }),
    "Update transitions to returned state")
  Assert.equal("exit:IDLE:RUNNING", events[1], "Exit runs before transition")
  Assert.equal("enter:RUNNING:IDLE", events[2], "Enter receives prior state")
  Assert.equal("DONE", machine:update(), "onUpdate alias dispatches")
  Assert.isFalse(machine:transition("DONE"), "Same-state transition is a no-op")
  Assert.throws(function() machine:transition("MISSING") end,
    "Unregistered transitions are rejected")
end
Assert.endTest()

Assert.startTest("MachineNode: shared and legacy status paths match")
do
  local legacy = MachineNode.new("legacy-node")
  local shared = MachineNode.new("shared-node", { useStateMachine = true })

  local function check(label)
    Assert.equal(legacy:getStatus(), shared:getStatus(), label)
    Assert.equal(legacy:hasFault(), shared:hasFault(), label .. " fault state")
  end

  check("Both begin AVAILABLE")
  Assert.equal(legacy:bindJob({ id = "job" }), shared:bindJob({ id = "job" }),
    "Both reject binding without a lock")
  check("Rejected binding keeps status")
  Assert.equal(legacy:lock(), shared:lock(), "Both acquire lock")
  check("Lock transitions match")
  Assert.equal(legacy:bindJob({ id = "job" }), shared:bindJob({ id = "job" }),
    "Both bind a valid job")
  check("Binding transitions match")
  Assert.equal(legacy:unlock(), shared:unlock(),
    "Both preserve PROCESSING unlock guard")
  check("Unlock guard keeps processing")
  Assert.equal(legacy:releaseJob(), shared:releaseJob(), "Both release jobs")
  check("Release transitions match")
  legacy:recordFault(42, "test fault")
  shared:recordFault(42, "test fault")
  check("Fault transitions match")
  Assert.equal(legacy:clearFault(), shared:clearFault(), "Both clear faults")
  check("Clearing fault transitions match")
end
Assert.endTest()

return true
