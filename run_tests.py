#!/usr/bin/env python3
"""
AE2-ES Lua Unit Test Runner (Python/lupa bridge)

Runs the Lua test suite using lupa (LuaJIT embedded in Python).
Handles the package path setup and reports results.
"""

import sys
import os

# Ensure the project root is on path
project_root = os.path.dirname(os.path.abspath(__file__))
os.chdir(project_root)

try:
    from lupa import LuaRuntime
except ImportError:
    print("ERROR: lupa is required. Install with: pip install lupa")
    sys.exit(1)

lua = LuaRuntime(unpack_returned_tuples=True)

# Set up package paths so Lua require() works
lua.execute("""
    package.path = "./src/?.lua;./?.lua;./tests/?.lua;./tests/?/init.lua;" .. package.path
""")

# Provide bit32 for LuaJIT (which doesn't have it natively)
lua.execute("""
    if not bit32 then
        bit32 = {
            bxor = function(a, b)
                local result = 0
                local bit = 1
                while a > 0 or b > 0 do
                    local a_bit = a % 2
                    local b_bit = b % 2
                    if a_bit ~= b_bit then
                        result = result + bit
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit = bit * 2
                end
                return result
            end,
            band = function(a, b)
                local result = 0
                local bit = 1
                while a > 0 and b > 0 do
                    if a % 2 == 1 and b % 2 == 1 then
                        result = result + bit
                    end
                    a = math.floor(a / 2)
                    b = math.floor(b / 2)
                    bit = bit * 2
                end
                return result
            end,
        }
    end
""")

# Load the assertion module first
try:
    lua.execute('require("tests.helpers.assertions")')
    print("Loaded assertions module OK")
except Exception as e:
    print(f"ERROR loading assertions: {e}")
    sys.exit(1)

# Load mock_env
try:
    lua.execute('require("tests.helpers.mock_env")')
    lua.execute('require("tests.helpers.mock_env").setup()')
    print("Loaded mock_env OK")
except Exception as e:
    print(f"ERROR loading mock_env: {e}")
    sys.exit(1)

# Define test files
test_files = [
    "tests.test_jit_db_cleanup",
    "tests.test_telemetry_serialization",
    "tests.test_malformed_payload",
    "tests.test_integration",
    "tests.test_soak",
    "tests.test_timeslicescheduler",
    "tests.test_state_transitions",
    "tests.test_profiler",
    "tests.unit.test_config_ui",
    "tests.unit.test_supervisor_config_ui",
]

# Run standalone test files (use dofile instead of require)
standalone_tests = [
    "MaintenanceReport_test.lua",
    "JobManifest_test.lua",
    "JobQueue_test.lua",
    "ttd_tracker_test.lua",
]

print("\nAE2-ES Unit Test Suite (via lupa/Python)")
print("=" * 45)
print()

# Run each test file
all_passed = True
for test_module in test_files:
    try:
        lua.execute(f'require("{test_module}")')
    except Exception as e:
        print(f"  ERROR in {test_module}: {e}")
        all_passed = False

# Run standalone test files (load module then dofile the test)
import os
for test_file in standalone_tests:
    test_path = os.path.join(project_root, test_file)
    if os.path.exists(test_path):
        try:
            # Determine the module file name from test file naming convention
            mod_file = test_file.replace('_test.lua', '.lua').replace('-test.lua', '.lua')
            mod_path = os.path.join(project_root, mod_file)
            # Load module into global
            lua.execute(f'MaintenanceReport = dofile({repr(mod_path)})')
            # Run the test (it uses arg[1] or falls back to MaintenanceReport global)
            lua.execute(f'dofile({repr(test_path)})')
        except Exception as e:
            print(f"  ERROR in {test_file}: {e}")
            all_passed = False

# Print summary
try:
    success = lua.eval('require("tests.helpers.assertions").summary()')
    all_passed = all_passed and success
except Exception as e:
    print(f"Error getting summary: {e}")
    all_passed = False

if all_passed:
    print("ALL TESTS PASSED")
    sys.exit(0)
else:
    print("SOME TESTS FAILED")
    sys.exit(1)
