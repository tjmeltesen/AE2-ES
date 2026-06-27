#!/bin/bash
# run_tier2.sh — AE2-ES Horizon-QA Tier 2 Test Runner
# Called by CI/CD pipeline (nightly-soak.yml) to execute real-mod integration tests.
#
# Runs the Horizon-QA Lua test harness against mock OC components (standalone mode)
# via the Python/lupa bridge (run_tier2.py).
#
# On a real GTNH headless server, this would invoke OC's lua runtime with
# actual components; in standalone mode, lupa provides the LuaJIT runtime.
#
# Usage:
#   ./horizon-qa/run_tier2.sh                  # run all tests via lupa
#   ./horizon-qa/run_tier2.sh --filter modem   # run tests matching "modem"
#   ./horizon-qa/run_tier2.sh --native          # run via native lua (requires lua 5.3+)
#   ./horizon-qa/run_tier2.sh --real            # run against real OC (GTNH server)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

# Parse flags
RUNNER="python3"
RUNNER_SCRIPT="horizon-qa/run_tier2.py"
LUA_BIN="lua"
FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --filter)
            FILTER="$2"
            shift 2
            ;;
        --filter=*)
            FILTER="${1#*=}"
            shift
            ;;
        --native)
            RUNNER="$LUA_BIN"
            RUNNER_SCRIPT="horizon-qa/runner.lua"
            shift
            ;;
        --real)
            # In --real mode, this would connect to the headless GTNH server's OC runtime.
            # For now, fall back to standalone with a warning.
            echo "WARNING: --real mode requires a GTNH headless server (C7 infrastructure)."
            echo "         Running in standalone mode with mock components."
            shift
            ;;
        *)
            echo "Unknown flag: $1"
            echo "Usage: $0 [--filter <pattern>] [--native] [--real]"
            exit 2
            ;;
    esac
done

echo "=== AE2-ES Horizon-QA Tier 2 Integration Tests ==="
echo "Runner: $RUNNER $RUNNER_SCRIPT"
if [[ -n "$FILTER" ]]; then
    echo "Filter: $FILTER"
fi
echo ""

# Install deps if needed (for lupa-based runs)
if [[ "$RUNNER" == "python3" ]]; then
    pip install -q -r requirements.txt 2>/dev/null || true
fi

# Run the test suite
if [[ "$RUNNER" == "python3" ]]; then
    python3 "$RUNNER_SCRIPT"
    EXIT_CODE=$?
else
    # Native Lua mode: use the runner.lua directly
    if [[ -n "$FILTER" ]]; then
        $LUA_BIN "$RUNNER_SCRIPT" --filter "$FILTER" --junit "horizon-qa-results.xml"
    else
        $LUA_BIN "$RUNNER_SCRIPT" --junit "horizon-qa-results.xml"
    fi
    EXIT_CODE=$?
fi

# Report
if [[ $EXIT_CODE -eq 0 ]]; then
    echo ""
    echo "=== ALL HORIZON-QA TIER 2 TESTS PASSED ==="
else
    echo ""
    echo "=== HORIZON-QA TIER 2 TESTS FAILED (exit code: $EXIT_CODE) ==="
fi

exit $EXIT_CODE
