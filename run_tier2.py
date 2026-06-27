#!/usr/bin/env python3
"""
AE2-ES Tier 2 Integration Test Runner (Python/lupa bridge)

Runs the C3 integration test suite using lupa (LuaJIT embedded in Python).
Covers modem broadcasting, HAL interfacing, redstone lock synchronization,
and fault injection/recovery. Designed for CI — completes in under 5 minutes.

Usage:
    python run_tier2.py
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
    package.path = "./src/?.lua;./?.lua;./tests/?.lua;./tests/?/init.lua;" ..
                  "./supervisor/?.lua;./supervisor/?/init.lua;" ..
                  "./exec_broker/?.lua;./exec_broker/?/init.lua;" ..
                  package.path
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

# Load and run the Tier 2 integration test runner
print("\nTier 2 Integration Test Suite (via lupa/Python)")
print("=" * 52)
print()

runner_path = os.path.join(project_root, "tests", "run_tier2.lua")
if not os.path.exists(runner_path):
    print(f"ERROR: Tier 2 runner not found at {runner_path}")
    sys.exit(1)

try:
    lua.execute(f'dofile({runner_path!r})')
except Exception as e:
    print(f"\nFATAL: Tier 2 integration runner crashed: {e}")
    sys.exit(1)

# The Lua runner calls os.exit(0) on success, os.exit(1) on failure.
# If we reach here without an exception, the tests passed.
sys.exit(0)
