-- Bounded FIFO list with optional bulk trimming. Safe to import outside OpenComputers.

local BoundedList = {}

local DEFAULT_MAX_SIZE = 100

local function validateBounds(maxSize, trimTarget)
  if type(maxSize) ~= "number" or maxSize < 1 or maxSize % 1 ~= 0 then
    error("maxSize must be a positive integer", 3)
  end
  if type(trimTarget) ~= "number" or trimTarget < 0
      or trimTarget > maxSize or trimTarget % 1 ~= 0 then
    error("trimTarget must be an integer between 0 and maxSize", 3)
  end
end

function BoundedList.__index(self, key)
  if type(key) == "number" then
    return self._entries[key]
  end
  return BoundedList[key]
end

function BoundedList.__len(self)
  return #self._entries
end

function BoundedList.new(maxSize, trimTarget)
  maxSize = maxSize or DEFAULT_MAX_SIZE
  trimTarget = trimTarget == nil and maxSize or trimTarget
  validateBounds(maxSize, trimTarget)

  return setmetatable({
    _entries = {},
    _maxSize = maxSize,
    _trimTarget = trimTarget,
  }, BoundedList)
end

function BoundedList:_trim()
  if #self._entries <= self._maxSize then return 0 end

  local removed = #self._entries - self._trimTarget
  for _ = 1, removed do
    table.remove(self._entries, 1)
  end
  return removed
end

function BoundedList:push(value)
  table.insert(self._entries, value)
  self:_trim()
  return #self._entries
end

function BoundedList:pushFront(value)
  table.insert(self._entries, 1, value)
  self:_trim()
  return #self._entries
end

function BoundedList:size()
  return #self._entries
end

function BoundedList:clear()
  local count = #self._entries
  self._entries = {}
  return count
end

function BoundedList:toTable()
  return self._entries
end

function BoundedList:average()
  if #self._entries == 0 then return nil end

  local total = 0
  for _, value in ipairs(self._entries) do
    if type(value) ~= "number" then
      error("average requires numeric entries", 2)
    end
    total = total + value
  end
  return total / #self._entries
end

function BoundedList:median()
  if #self._entries == 0 then return nil end

  local values = {}
  for index, value in ipairs(self._entries) do
    if type(value) ~= "number" then
      error("median requires numeric entries", 2)
    end
    values[index] = value
  end
  table.sort(values)

  local middle = math.floor((#values + 1) / 2)
  if #values % 2 == 1 then return values[middle] end
  return (values[middle] + values[middle + 1]) / 2
end

return BoundedList
