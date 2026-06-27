-- BufferSnapshot module
-- Transient structure for Phase 1-2 buffer comparison.
-- Checksum-based stability detection over debounce window (1-2 seconds).

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
  -- Sort keys for deterministic output
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

  -- Simple FNV-1a style hash
  local hash = 2166136261
  local str = table.concat(parts, "|")
  for i = 1, #str do
    hash = bit32.bxor(hash, string.byte(str, i))
    hash = hash * 16777619
    hash = bit32.band(hash, 0xFFFFFFFF)
  end
  return string.format("%08x", hash)
end

--- Create a new BufferSnapshot
--- @param buffer table snapshot of AE2 interface contents
--- @return BufferSnapshot
function BufferSnapshot.new(buffer)
  local self = setmetatable({}, BufferSnapshot)
  self.buffer = buffer or {}
  self.checksum = BufferSnapshot.generateChecksum(buffer)
  self.timestamp = os.epoch and os.epoch() or os.time()
  self._stableCount = 0
  return self
end

--- Compare two snapshots and update debounce state
--- @param other BufferSnapshot
--- @param debounceThreshold number seconds of stability required (default 1.5)
--- @return boolean true if buffer is stable (ready to transition)
function BufferSnapshot:compareAndDebounce(other, debounceThreshold)
  debounceThreshold = debounceThreshold or 1.5

  if not other then
    self._stableCount = 0
    return false
  end

  if self.checksum == other.checksum then
    local elapsed = math.abs(self.timestamp - other.timestamp)
    if elapsed >= debounceThreshold then
      self._stableCount = (self._stableCount or 0) + 1
      return true
    end
  else
    self._stableCount = 0
  end

  return false
end

--- Convert this snapshot into a JobManifest
--- This triggers the LOGGING→ALLOCATING transition.
--- @param jobManifestModule table JobManifest module reference
--- @param jobId string
--- @return table JobManifest
function BufferSnapshot:convertToManifest(jobManifestModule, jobId)
  if not jobManifestModule then return nil end

  local manifest = jobManifestModule.new(jobId)
  for itemKey, itemData in pairs(self.buffer) do
    local qty = itemData.size or itemData.count or 1
    manifest:registerInput(itemKey, qty)
  end
  manifest:updateState(manifest.STATE.LOGGING)
  return manifest
end

--- Get the current stable count (debounce counter)
--- @return number
function BufferSnapshot:getStableCount()
  return self._stableCount or 0
end

--- Force-reset the debounce counter
function BufferSnapshot:resetDebounce()
  self._stableCount = 0
end

return BufferSnapshot
