## Summary

<!-- Briefly describe the purpose of this PR. What does it change or fix? -->
<!-- Example: "Fixes EC2 mid-transfer fault detection by adding a pcall boundary around HAL.transferItem" -->



## Changes

<!-- List the key files modified, added, or removed and what was changed in each. -->

| File | Change |
|------|--------|
| `src/...` | <!-- what and why --> |
| `tests/...` | <!-- what and why --> |

<!-- If this is a Lua module change, describe how the 6-phase state machine is affected (if at all). -->
**State machine impact:** <!-- BUFFERING / LOGGING / ALLOCATING / TRANSFERRING / PROCESSING / CLEANUP / None -->

---

## Testing

### Tier 1: Unit Tests (pre-commit)
<!-- Run locally before opening the PR: -->
```bash
python run_tests.py
python run_dashboard_tests.py
```
- [ ] Tier 1 tests pass locally

### Tier 2: Nightly Soak (integration)
<!-- Triggered automatically on schedule and workflow_dispatch. If your change affects
     broker-machine interaction, redstone locking, or telemetry, run a manual soak: -->
```bash
# Run the full test suite 5x (same as Tier 2)
python5() { for i in 1 2 3 4 5; do echo "=== Iteration $i ===" && python run_tests.py || return 1; done; }
python5
```
- [ ] Tier 2 passes (5 iterations, no flaky failures)

### Tier 3: Extended Soak + Profiling
<!-- Triggered nightly or via workflow_dispatch. This runs 1K micro-jobs, saturation
     stress, ghost-item timeout validation, and time-slice profiling. -->
```bash
python tests/run_tier3.py
```
- [ ] Tier 3 Extended Soak passes

## Performance Impact

<!-- Provide before/after numbers if your change may affect memory or timing. -->

| Metric | Before | After | Threshold |
|--------|--------|-------|-----------|
| GC memory delta (KB) | | | < 15% of baseline |
| Yield gap (seconds) | | | < 4s |
| Test runtime (seconds) | | | — |
| Job crashes | | | 0 |
| Assertions passed | | | — |

**Memory leak risk:** <!-- High / Medium / Low / None — explain why -->
**Yield gap risk:** <!-- High / Medium / Low / None — explain why -->

---

## Checklist

- [ ] Tier 1 unit tests pass (no regressions)
- [ ] Tier 2 nightly soak passes (5x repetition)
- [ ] Tier 3 extended soak passes (1K micro-jobs — `python tests/run_tier3.py`)
- [ ] No memory leaks detected (GC delta < 15% of baseline)
- [ ] No yield gaps over 4s
- [ ] No job crashes during soak
- [ ] Performance report artifact uploaded (Tier 3)
- [ ] Documentation updated if public API / configuration changed
- [ ] Edge cases considered (premature unlock, mid-transfer fault, ghost items, saturation, maintenance recovery)

---

<!-- PR metadata for CI — do not remove -->
/label ~"needs-review"
