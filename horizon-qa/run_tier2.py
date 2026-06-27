#!/usr/bin/env python3
"""
Horizon-QA Tier 2 Lua Test Runner (Python/lupa bridge)

Runs the Horizon-QA Lua test suite using lupa (LuaJIT embedded in Python).
Called by run_tier2.sh for CI integration.
Produces JUnit XML output for GitHub Actions reporting.
"""
import sys
import os
import json
import time

# Project root is 2 levels up from this script
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(project_root)

try:
    from lupa import LuaRuntime
except ImportError:
    print("ERROR: lupa is required. Install with: pip install lupa")
    sys.exit(1)

lua = LuaRuntime(unpack_returned_tuples=True)

# Set up package paths
lua.execute("""
    package.path = "./src/?.lua;./?.lua;./tests/?.lua;./tests/?/init.lua;./horizon-qa/?.lua;" .. package.path
""")

# Provide bit32 for LuaJIT
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

# Load assertion and mock modules
try:
    lua.execute('require("tests.helpers.assertions")')
    lua.execute('require("tests.helpers.mock_env")')
    lua.execute('require("tests.helpers.mock_modules")')
    print("Loaded test helpers OK")
except Exception as e:
    print(f"ERROR loading helpers: {e}")
    sys.exit(1)

# Load JSON writer
try:
    lua.execute('require("horizon-qa.json_writer")')
except Exception as e:
    print(f"ERROR loading json_writer: {e}")
    sys.exit(1)

# Define Horizon-QA test files
hq_test_files = [
    "horizon-qa.tests.hq_test_modem",
    "horizon-qa.tests.hq_test_transposer",
    "horizon-qa.tests.hq_test_maintenance",
    "horizon-qa.tests.hq_test_debounce",
    "horizon-qa.tests.hq_test_ghost",
    "horizon-qa.tests.hq_test_saturation",
]

print("\nAE2-ES Horizon-QA Tier 2 Integration Test Suite")
print("=" * 50)
print()

# Track results for JUnit XML generation
junit_results = []

for test_module in hq_test_files:
    test_name = test_module.split(".")[-1]
    start_time = time.time()

    try:
        lua.execute(f'require("tests.helpers.assertions").reset()')
        lua.execute(f'dofile("horizon-qa/tests/{test_name}.lua")')
        duration = time.time() - start_time

        # Check assertions
        results = lua.eval('require("tests.helpers.assertions").getResults()')
        total_assertions = sum(r.assertions for r in results if hasattr(r, 'assertions'))
        total_failures = sum(r.failures for r in results if hasattr(r, 'failures'))

        if total_failures > 0:
            print(f"  FAIL  {test_name}  ({total_assertions} assertions, {total_failures} failures, {duration:.2f}s)")
            errors = []
            for r in results:
                for e in getattr(r, 'errors', []) or []:
                    errors.append(f"{r.name}: {e}")
                    print(f"        {r.name}: {e}")
            junit_results.append({
                "name": test_name,
                "status": "FAIL",
                "assertions": total_assertions,
                "failures": total_failures,
                "duration": duration,
                "errors": errors,
            })
        else:
            print(f"  PASS  {test_name}  ({total_assertions} assertions, {duration:.2f}s)")
            junit_results.append({
                "name": test_name,
                "status": "PASS",
                "assertions": total_assertions,
                "failures": 0,
                "duration": duration,
            })

    except Exception as e:
        duration = time.time() - start_time
        print(f" ERROR  {test_name}  ({duration:.2f}s)")
        print(f"        {e}")
        junit_results.append({
            "name": test_name,
            "status": "ERROR",
            "assertions": 0,
            "failures": 0,
            "duration": duration,
            "errors": [str(e)],
        })

# Write JUnit XML
junit_path = os.path.join(project_root, "horizon-qa-results.xml")

passed = sum(1 for r in junit_results if r["status"] == "PASS")
failed = sum(1 for r in junit_results if r["status"] == "FAIL")
errors = sum(1 for r in junit_results if r["status"] == "ERROR")
total = len(junit_results)
total_time = sum(r["duration"] for r in junit_results)

xml_lines = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    f'<testsuite name="AE2-ES Horizon-QA Tier 2" tests="{total}" failures="{failed}" errors="{errors}" time="{total_time:.3f}">',
]

for r in junit_results:
    xml_lines.append(
        f'  <testcase classname="AE2-ES.HorizonQA" name="{r["name"]}" time="{r["duration"]:.3f}">'
    )
    if r["status"] == "FAIL":
        msg = r.get("errors", ["test failed"])[0]
        xml_lines.append(
            f'    <failure message="{r["failures"]} failures"><![CDATA[{msg}]]></failure>'
        )
    elif r["status"] == "ERROR":
        msg = r.get("errors", ["runtime error"])[0]
        xml_lines.append(
            f'    <error message="Runtime error"><![CDATA[{msg}]]></error>'
        )
    xml_lines.append("  </testcase>")

xml_lines.append("</testsuite>")

with open(junit_path, "w") as f:
    f.write("\n".join(xml_lines) + "\n")

print(f"\nJUnit XML written to: {junit_path}")

# Write JSON summary
json_path = os.path.join(project_root, "horizon-qa-results.json")
summary = {
    "runner": "horizon-qa/run_tier2.py",
    "total": total,
    "passed": passed,
    "failed": failed,
    "errors": errors,
    "total_assertions": sum(r["assertions"] for r in junit_results),
    "total_failures": sum(r["failures"] for r in junit_results),
    "duration": total_time,
    "results": junit_results,
}

with open(json_path, "w") as f:
    json.dump(summary, f, indent=2)

print(f"Results JSON written to: {json_path}")

# Exit code
if failed > 0 or errors > 0:
    print("\nSOME HORIZON-QA TESTS FAILED")
    sys.exit(1)
else:
    print("\nALL HORIZON-QA TESTS PASSED")
    sys.exit(0)
