-- state_machine.lua
-- Small, dependency-free state machine for tick-driven controllers.

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new(initialState, data)
  assert(type(initialState) == "string" and #initialState > 0,
    "StateMachine requires a non-empty initial state")

  return setmetatable({
    _state = initialState,
    _data = data,
    _states = {},
  }, StateMachine)
end

function StateMachine:addState(name, hooks)
  assert(type(name) == "string" and #name > 0,
    "StateMachine state name must be a non-empty string")
  assert(hooks == nil or type(hooks) == "table",
    "StateMachine state hooks must be a table")

  self._states[name] = hooks or {}
  return self
end

local function hookFor(hooks, name)
  return hooks[name] or hooks["on" .. name:sub(1, 1):upper() .. name:sub(2)]
end

function StateMachine:transition(name, context)
  assert(type(name) == "string" and #name > 0,
    "StateMachine transition target must be a non-empty string")
  assert(self._states[name] ~= nil,
    "StateMachine transition target is not registered: " .. name)

  local previous = self._state
  if previous == name then
    return false
  end

  local currentHooks = self._states[previous]
  local exit = currentHooks and hookFor(currentHooks, "exit")
  if exit then
    exit(self._data, context, name, previous)
  end

  self._state = name
  local enter = hookFor(self._states[name], "enter")
  if enter then
    enter(self._data, context, previous, name)
  end

  return true
end

function StateMachine:update(context)
  local hooks = self._states[self._state]
  assert(hooks ~= nil, "StateMachine current state is not registered: " .. self._state)

  local update = hookFor(hooks, "update")
  if not update then
    return self._state
  end

  local nextState = update(self._data, context, self._state)
  if nextState ~= nil and nextState ~= self._state then
    self:transition(nextState, context)
  end
  return self._state
end

function StateMachine:getState()
  return self._state
end

return StateMachine
