--[[
log_filter.lua — LogFilter (D2)
AE2 Execution System (AE2-ES)

Criteria-based log query engine for the Global Logger.
Filters a buffer of log entries by zero or more criteria combined with AND logic.
Pure module — no mutable state, no IO. Returns new tables, never mutates input.

Log entry format (consumed by both LogFilter and LogExporter):
  {
    timestamp = os.epoch() or os.time(),
    severity  = "INFO" | "WARNING" | "ERROR" | "CRITICAL",
    originId  = string — broker or component identifier (e.g. "EB-LCR-01"),
    message   = string — free-form log message,
  }

Criteria format:
  { severity = "ERROR", originId = "EB-LCR-01" }
  A nil value for any key means "match all" for that key.
  Multiple keys are combined with AND logic.
]]

local LogFilter = {}

-- ===========================================================================
-- Internal: match a single log entry against a single criterion field
-- ===========================================================================

--- Check whether a log entry field matches a criterion value.
-- A nil criterion matches anything (wildcard).
-- A string criterion is compared directly.
-- @param entryValue  any — the value from the log entry
-- @param criterionValue  any — the value from the criteria table (nil = wildcard)
-- @return boolean
local function matchesField(entryValue, criterionValue)
  if criterionValue == nil then
    return true  -- wildcard: match all
  end
  return tostring(entryValue) == tostring(criterionValue)
end

-- ===========================================================================
-- Internal: check if a single entry matches all criteria
-- ===========================================================================

--- Test a single log entry against all supplied criteria.
-- All criteria must match (AND semantics).
-- @param entry      table — a log entry
-- @param criteria   table — filter criteria { severity?, originId?, message? }
-- @return boolean
local function entryMatches(entry, criteria)
  for field, criterionValue in pairs(criteria) do
    local entryValue = entry[field]
    if not matchesField(entryValue, criterionValue) then
      return false
    end
  end
  return true
end

-- ===========================================================================
-- Public API
-- ===========================================================================

--- Execute a filter against a source buffer.
-- Returns a new table containing only the entries that match all criteria.
-- The source buffer is never mutated.
--
-- @param sourceBuffer  table — array of log entries to filter
-- @param criteria      table — optional, filter criteria { severity?, originId?, message? }
--                      When nil or empty, returns all entries (pass-through).
-- @return table  array of matching log entries (may be empty)
function LogFilter.execute(sourceBuffer, criteria)
  if type(sourceBuffer) ~= "table" then
    return {}
  end

  -- No criteria or empty criteria → pass-through (match all)
  if criteria == nil or next(criteria) == nil then
    local result = {}
    for _, entry in ipairs(sourceBuffer) do
      table.insert(result, entry)
    end
    return result
  end

  local result = {}
  for _, entry in ipairs(sourceBuffer) do
    if entryMatches(entry, criteria) then
      table.insert(result, entry)
    end
  end
  return result
end

return LogFilter
