# Session Handoff — 2026-07-20 Scheduler Wiring & Transfer Optimization

## Files changed

| File | Change |
|------|--------|
| `src/scheduler_registry.lua` | **Created** — singleton scheduler accessor |
| `src/exec_broker.lua` | Scheduler mandatory, registry.set(), dead flags removed, legacy hooks removed, telemetry uses forEach |
| `src/phases/allocating.lua` | forEachPair loop, scheduler_registry import |
| `src/phases/processing.lua` | forEachPair loop, scheduler_registry import |
| `src/phases/cleanup.lua` | Drain removed, release-only, forEachPair, nil-guard |
| `src/phases/transferring.lua` | Deferred path restored (singleton-based), wait step removed, pull step optimized (drain-first, reconfigure), fluid skip |
| `src/phases/logging.lua` | Diagnostic log for manifest items/fluids counts |
| `tests/test_phase_modules.lua` | Scheduler mock updated, singleton set |
| `tests/test_scheduler_integration.lua` | Updated for always-on scheduler |

## Architecture

### Scheduler singleton
`src/scheduler_registry.lua` — one `set()` call at broker startup, all phases call `.get()` in `execute()`. No context parameter, no nil-guards, no caller dependency.

### Phase loop protection
All phase `execute()` methods use `schedulerRegistry.get():forEachPair()` / `:forEach()` instead of raw `pairs()`/`ipairs()`. Budget checked every 200 iterations, `os.sleep(0)` yield to prevent TMI.

### Deferred transfer sub-pipeline
`_scheduleCoroutine` uses `schedulerRegistry.get():defer(step)`. One sub-step per tick, re-queued until `_transferStep` is nil. `processQueue()` drains the queue in the broker's `tick()` after the intake pipeline.

### Transfer sub-pipeline (current flow)
```
store → stock → pull → verify → clear → PROCESSING
```
- **Wait step removed** — AE2 configures interface instantly, no need for 6-tick blind delay
- **Pull step**: drains once unconditionally (`_drainCalled` flag), then checks `getMEContents`. If items/fluids remain → reconfigure matching entries via `configureInterfaceStocking`/`configureFluidExport` → drain again. If both 0 → skip to clear
- **Fluids-only jobs**: stock→pull skips drain (no items), goes verify→clear in 1 extra tick
- **Cleanup**: release-only (drain moved to transferring→PROCESSING transition point, then to processing's first check)

### Critical bug fixed
`forEachPair` callbacks used `return false` as stop signal — the real `TimeSliceScheduler:forEachPair` ignores return values (only the test mock honored it). This permanently blocked dispatch because the TRANSFERRING check never stopped iterating. Fixed with `if found then return end` guard pattern.

### Processing phase
- Wake timer from progress bar (95% of `maxProgress/20`)
- Stale check gated behind "no progress bar" condition (long recipes not falsely faulted)
- Fast recipe detection (< 2s)
- Completion health gate before releasing machine

### Intake backoff
When allocating stuck (no healthy machine): computes `_intakeBackoff` from earliest processing `_wakeTime`. Skips intake pipeline until then. Returns nil (no backoff) when no processing jobs — polls every tick.

## Test suite
204 total, 202 passed, 2 failed. Both failures are pre-existing (G2a/G2b integration tests — missing mock HAL method, manifest isStale timing).

## Deferred: parallel health cache
Discussed but not implemented. With 4 machines, the health check (`quickHealthCheck` → 4 component calls per machine) is fast enough (~200ms). Cache would save ~200ms per allocating tick after first scan, negligible at 4-machine scale. Revisit if machine count grows.

### Design notes for future
- Cache per-machine `{ok, healthScore, issues}` in MachineNode
- TTL 5s, invalidate on state change (fault, completion, lock, release)
- HAL:quickHealthCheck checks cache first, only polls sensor if stale
