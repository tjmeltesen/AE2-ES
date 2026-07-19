#!/usr/bin/env python3
"""
AE2-ES Tier 3 Extended Soak Test Runner (Python/lupa bridge)

Runs the Tier 3 test suite:
  - test_soak.lua (1K micro-jobs, saturation stress, ghost items)
  - test_timeslicescheduler.lua (profiling)
  
Produces a performance report JSON artifact.
Detects: memory leaks, yield gaps > 4s, job crashes.
"""

import json
import sys
import os

project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(project_root)

try:
    from lupa import LuaRuntime
except ImportError:
    print("ERROR: lupa is required. Install with: pip install lupa")
    sys.exit(1)

lua = LuaRuntime(unpack_returned_tuples=True)

# Set up package paths so Lua require() works
lua.execute("""
    package.path = "./src/?.lua;./lib/?.lua;./?.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path
""")

# Provide bit32 for LuaJIT
lua.execute("""
    if not bit32 then
        bit32 = {
            bxor = function(a, b)
                local result = 0; local bit = 1
                while a > 0 or b > 0 do
                    if (a % 2) ~= (b % 2) then result = result + bit end
                    a = math.floor(a/2); b = math.floor(b/2); bit = bit * 2
                end
                return result
            end,
            band = function(a, b)
                local result = 0; local bit = 1
                while a > 0 and b > 0 do
                    if a % 2 == 1 and b % 2 == 1 then result = result + bit end
                    a = math.floor(a/2); b = math.floor(b/2); bit = bit * 2
                end
                return result
            end,
        }
    end
""")

# Load assertions and mock environment
try:
    lua.execute('require("tests.helpers.assertions")')
    print("Loaded assertions module OK")
except Exception as e:
    print(f"ERROR loading assertions: {e}")
    sys.exit(1)

try:
    lua.execute('require("tests.helpers.mock_env")')
    lua.execute('require("tests.helpers.mock_env").setup()')
    print("Loaded mock_env OK")
except Exception as e:
    print(f"ERROR loading mock_env: {e}")
    sys.exit(1)


def lua_table_to_dict(table):
    """Convert a lupa Lua table to a plain Python dict."""
    if table is None:
        return None
    return {key: table[key] for key in table}


# Run the tier3 Lua runner
print("\nAE2-ES Tier 3 Extended Soak Test Suite")
print("=" * 50)
print()

# Stub os.exit so dofile returns and _G.TIER3_REPORT remains readable
lua.execute("""
    os.exit = function(code)
        _G.TIER3_EXIT_CODE = code or 0
    end
""")

success = True
job_crashes = 0

try:
    lua.execute('dofile("tests/run_tier3.lua")')
except Exception as e:
    print(f"Tier 3 runner error: {e}")
    success = False
    job_crashes = 1

# Read performance report from Lua (soak-phase memory gate)
lua_report = lua_table_to_dict(lua.globals().TIER3_REPORT)
if lua_report is None:
    print("ERROR: TIER3_REPORT not set by Lua runner", file=sys.stderr)
    sys.exit(1)

memory_leak = bool(lua_report.get("memory_leak_detected", False))
yield_gap = bool(lua_report.get("yield_gap_over_4s", False))
failures = int(lua_report.get("failures", 0))
job_crashes = max(job_crashes, int(lua_report.get("job_crashes", 0)))
mem_delta_soak = float(lua_report.get("gc_memory_delta_soak_kb", 0))

report = dict(lua_report)
report["success"] = (
    success
    and failures == 0
    and not memory_leak
    and not yield_gap
    and job_crashes == 0
)

report_path = "tier3-performance-report.json"
with open(report_path, "w") as f:
    json.dump(report, f, indent=2)

print(f"\nTier 3 Report: {json.dumps(report, indent=2)}")
print(f"Report written to: {report_path}")

# Check failure conditions
if not success or failures > 0:
    print("ERROR: Tier 3 tests failed!", file=sys.stderr)
    sys.exit(1)

if memory_leak:
    print(
        f"FAIL: Memory leak detected during soak! ({mem_delta_soak:.1f} KB soak delta)",
        file=sys.stderr,
    )
    sys.exit(1)

if yield_gap:
    elapsed = float(lua_report.get("elapsed_seconds", 0))
    print(f"FAIL: Yield gap {elapsed:.1f}s exceeds 4s threshold!", file=sys.stderr)
    sys.exit(1)

if job_crashes > 0:
    print(f"FAIL: {job_crashes} job crash(es) detected!", file=sys.stderr)
    sys.exit(1)

print("All Tier 3 thresholds passed.")
sys.exit(0)
