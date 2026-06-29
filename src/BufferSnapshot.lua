-- BufferSnapshot module
-- Transient structure for Phase 1-2 buffer comparison.
-- Checksum-based stability detection over debounce window (1-2 seconds).
--
-- API (new, used by exec_broker):
--   new(debounceWindow)  — constructor with debounce window in seconds
--   :update(bufferData)  — feed new poll data, returns true when stable
--   :getSnapshotData()   — returns {items={...}, fluids={...}}
--   :convertToManifest(jobId) — create a JobManifest (1-arg) or (module, jobId) (2-arg)
--   :reset()             — clear internal state for fresh cycle
--
-- Backward compat (used by test_state_transitions):
--   new(bufferTable)     — old-style constructor with buffer data
--   :compareAndDebounce(other, threshold) — old debounce check
--   :getStableCount()
--   :resetDebounce()

local BufferSnapshot = {}
BufferSnapshot.__index = BufferSnapshot

--- Generate a checksum from a buffer table
--- Simple deterministic hash for item stacks
--- @param buffer table of item entries
--- @return string hex checksum
function BufferSnapshot.generateChecksum(buffer)
  if not buffer or type(buffer) ~= "table" then
    return "00000000"
  end

  local parts = {}
  local keys = {}
  for k, _ in pairs(buffer) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

  for _, k in ipairs(keys) do
    local v = buffer[k]
    if type(v) == "table" then
      table.insert(parts, string.format("%s:%s:%d",
        tostring(k), tostring(v.label or v.name or "?"),
        tonumber(v.size or v.count or 0) or 0))
    else
      table.insert(parts, string.format("%s:%d", tostring(k), tonumber(v) or 0))
    end
  end

  -- Pure Lua FNV-1a style hash (no bit/bit32 library needed)
  local hash = 2166136261
  local str = table.concat(parts, "|")
  for i = 1, #str do
    hash = (hash + string.byte(str, i)) * 16777619
    hash = hash % 0x100000000
  end
  return string.format("%08x", hash)
end

--- Create a new BufferSnapshot
--- Supports both old (buffer table) and new (debounceWindow number) calling conventions.
--- @param arg number (debounceWindow) or table (old-style buffer for backward compat)
--- @return BufferSnapshot
function BufferSnapshot.new(arg)
  local self = setmetatable({}, BufferSnapshot)

  -- Backward compat: if arg is a table, treat as old-style buffer
  if type(arg) == "table" then
    self.buffer = arg
    self.checksum = BufferSnapshot.generateChecksum(arg)
    self.timestamp = (os.epoch and os.epoch()) or os.time()
    self._debounceWindow = 1.5
  else
    self._debounceWindow = (type(arg) == "number" and arg) or 1.5
  end

  self._lastBuffer = nil
  self._lastChecksum = nil
  self._stableCount = 0
  self._lastTimestamp = nil
  return self
end

--- Compare two snapshots and update debounce state (backward compat)
--- Works with old-style (self.checksum/self.timestamp).
--- @param other BufferSnapshot
--- @param debounceThreshold number ms of stability required (default 1500)
--- @return boolean true if buffer is stable (ready to transition)
function BufferSnapshot:compareAndDebounce(other, debounceThreshold)
  debounceThreshold = debounceThreshold or 1500

  if not other then
    self._stableCount = 0
    return false
  end

  local myCS = self.checksum or self._lastChecksum
  local otherCS = other.checksum or other._lastChecksum
  local myTs = self.timestamp or self._lastTimestamp or 0
  local otherTs = other.timestamp or other._lastTimestamp or 0

  if myCS and myCS == otherCS then
    local elapsed = math.abs(myTs - otherTs)
    if elapsed >= debounceThreshold then
      self._stableCount = (self._stableCount or 0) + 1
      return true
    end
  else
    self._stableCount = 0
  end

  return false
end


function BufferSnapshot.hasContent(bufferData)
  if not bufferData then return false end

  -- New-style: {items=[...], fluids=[...]}
  if type(bufferData.items) == "table" and #bufferData.items > 0 then
    return true
  end
  if type(bufferData.fluids) == "table" and #bufferData.fluids > 0 then
    return true
  end

  -- Old-style: buffer IS the array
  if bufferData[1] ~= nil then return true end

  return false
end
--- Update buffer data from exec_broker (time-based debounce)
--- Stores bufferData, computes checksum, compares with previous.
--- Returns true when the same checksum has been stable for >= debounceWindow seconds.
--- @param bufferData table data from bufferFeeder with .items and .fluids
--- @return boolean true if buffer is stable (ready to transition)
--- Check if a buffer actually has any content
--- @param bufferData table
--- @return boolean
function BufferSnapshot:update(bufferData)
  if not bufferData or not BufferSnapshot.hasContent(bufferData) then
    -- Empty buffer: reset stability but don't start a window
    self._lastBuffer = nil
    self._lastChecksum = nil
    self._stableCount = 0
    self._lastTimestamp = nil
    self._stableSince = nil
    return false
  end

  local checksum = BufferSnapshot.generateChecksum(bufferData)
  local now = os.time()

  if self._lastChecksum and self._lastChecksum == checksum then
    if self._stableSince then
      local elapsed = now - self._stableSince
      if elapsed >= self._debounceWindow then
        self._stableCount = (self._stableCount or 0) + 1
        self._lastTimestamp = now
        self._lastBuffer = bufferData
        self._lastChecksum = checksum
        return true
      end
    end
    self._stableCount = (self._stableCount or 0) + 1
  else
    -- Checksum changed — start fresh stability window
    self._stableCount = 1
    self._stableSince = now
  end

  self._lastBuffer = bufferData
  self._lastChecksum = checksum

  return false
end


--- Get separated snapshot data: items and fluids
--- @return table {items = {...}, fluids = {...}}
function BufferSnapshot:getSnapshotData()
  local buffer = self._lastBuffer or self.buffer
  if not buffer then
    return { items = {}, fluids = {} }
  end

  local items = {}
  local fluids = {}

  -- New-style buffer: {items=[...], fluids=[...]}
  if type(buffer.items) == "table" then
    for _, v in ipairs(buffer.items) do
      table.insert(items, {
        label  = v.label,
        size   = v.size,
        name   = v.name,
        damage = v.damage,
        nbt    = v.nbt,
      })
    end
  end
  if type(buffer.fluids) == "table" then
    for _, v in ipairs(buffer.fluids) do
      table.insert(fluids, { label = v.label, amount = v.amount })
    end
  end

  -- Old-style backward compat: buffer IS the items array
  if buffer[1] ~= nil and type(buffer[1]) == "table" then
    for _, v in ipairs(buffer) do
      table.insert(items, {
        label  = v.label,
        size   = v.size,
        name   = v.name,
        count  = v.count,
        damage = v.damage,
        nbt    = v.nbt,
      })
    end
  end

  return { items = items, fluids = fluids }
end

--- Reset all internal state for a fresh buffering cycle
function BufferSnapshot:reset()
  self._lastBuffer = nil
  self._lastChecksum = nil
  self._stableCount = 0
  self._lastTimestamp = nil
  self._stableSince = nil
end

--- Convert this snapshot into a JobManifest
--- Supports both old (2-arg) and new (1-arg) calling conventions.
--- @param arg1 string (jobId, new API) or table (jobManifestModule, old API)
--- @param arg2 string (jobId, old API only)
--- @return table JobManifest
function BufferSnapshot:convertToManifest(arg1, arg2)
  local JobManifestMod, jobId

  if type(arg1) == "table" then
    -- Old API: convertToManifest(jobManifestModule, jobId)
    JobManifestMod = arg1
    jobId = arg2
  else
    -- New API: convertToManifest(jobId)
    -- Use root-level JobManifest.lua (canonical version with id, status)
    JobManifestMod = require("JobManifest")
    jobId = arg1
  end

  local manifest = JobManifestMod.new(jobId)

  -- Set fields that exec_broker expects
  manifest.priority = 0
  manifest.createdAt = os.time()
  manifest.updatedAt = os.time()
  manifest.status = 'LOGGING'

  -- Update manifest state properly for the old API (test_state_transitions)
  if type(arg1) == "table" and manifest.state then
    manifest:updateState("LOGGING")
  end

  -- Separate items and fluids from the buffered data
  local snapshotData = self:getSnapshotData()
  manifest.inputs = {
    items = snapshotData.items,
    fluids = snapshotData.fluids
  }

  -- Old API: register each input individually (for _inputRegistry backward compat)
  if type(arg1) == "table" and manifest.registerInput then
    if snapshotData.items then
      for _, item in ipairs(snapshotData.items) do
        manifest:registerInput(item.name or item.label or "unknown", item.size or 0)
      end
    end
  end

  return manifest
end

--- Get the current stable count (debounce counter)
--- @return number
function BufferSnapshot:getStableCount()
  return self._stableCount or 0
end

--- Force-reset the debounce counter (alias for reset)
function BufferSnapshot:resetDebounce()
  self:reset()
end

return BufferSnapshot
