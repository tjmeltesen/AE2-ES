# AE2-ES State Machine Audit — 2026-07-19

## Flow Diagram

```
  ┌─────────┐    ┌─────────┐    ┌────────────┐    ┌──────────────┐
  │BUFFERING│───→│ LOGGING │───→│ ALLOCATING │───→│ TRANSFERRING │
  │  poll   │    │ snapshot│    │ health-check│   │ 6-step pipe  │
  │  buffer │    │→manifest│    │ pick best   │   │ store→stock  │
  │  debounce│   │→ queue  │    │ lock+bind   │   │ →wait→pull   │
  └─────────┘    └─────────┘    └────────────┘   │ →verify→clear│
       ↑               │              │  │        └──────┬───────┘
       │               │              │  │               │
       │  empty/        │  queue       │  │ no healthy    │  all transferred
       │  unstable      │  full        │  │ machine       │
       │               ↓              │  │               ↓
       └───────────────┴──────────────┘  │         ┌──────────────┐
                                         │         │  PROCESSING  │← back-end
                      ┌──────────────────┘         │  wake-timer  │  runs every
                      │  intake backoff             │  fast-recipe │  tick
                      │  (sleep until earliest      │  health-gate │
                      │   _wakeTime on any          └──────┬───────┘
                      │   processing machine)              │  done/fault
                      └────────────────────────────────────┘
                                                           ↓
                                                    ┌──────────────┐
                                                    │   CLEANUP    │← back-end
                                                    │  drain items │  runs every
                                                    │  release lane│  tick
                                                    │  update stats│
                                                    └──────────────┘

  Phase transitions:
    BUFFERING → LOGGING      stable snapshot w/ data
    LOGGING   → ALLOCATING   manifest pushed to queue
    ALLOCATING→ TRANSFERRING healthy machine locked
    TRANSFERRING→ALLOCATING  all transfers complete
    PROCESSING→ CLEANUP      recipe done or faulted
    CLEANUP   → (removed)    lane freed from activeJobs
    *         → BUFFERING    queue empty
```

## Phase Module Call Traces

### BUFFERING (runs when pollInterval fires)
- bufferFeeder() → HAL.getMEContents (auto-created if meControllerAddr set)
- snapshot.update(bufferData) → BufferSnapshot
- snapshot.getSnapshotData() → items/fluids table
- snapshot.reset()
- (optional) _checkAutoCrafting() → HAL.requestCraft every 5th poll

### LOGGING (runs every tick while in LOGGING)
- snapshot.convertToManifest() → manifest table
- JobManifest.new() → job object
- queue.push(job) → boolean
- snapshot.reset()

### ALLOCATING (runs every tick, gated by intakeBackoff)
- queue.popNextAvailable() → job or nil
- For each machine: HAL.quickHealthCheck(node) → {ok, healthScore, issues}
  - Internally: getProxy → hasWork/isMachineActive/isWorkAllowed
    → getSensorInformation → node:updateHealth
- node.lock() → boolean
- node.bindJob(job) → boolean
- job.bindHardware(address)
- On failure: queue.push(job) re-queue

### TRANSFERRING (sub-pipeline advances one step per tick)
- Promote: ALLOCATING→TRANSFERRING batch
- Timeout guard: _transferStartedAt tracking
- store step: HAL.storeNetworkEntry(meAddr, filter, dbAddr, slot)
- stock step: HAL.configureInterfaceStocking / configureFluidExport
- wait step: tick counter + HAL.checkInterfaceStocked
- pull step: HAL.drainInventory
- clear step: HAL.clearInterfaceSlot / clearFluidExport
    / clearDatabaseSlot / pulseRedstoneLock
- On complete: manifest.updateState("PROCESSING")

### PROCESSING (runs every tick, not gated)
- HAL.pollMachineHardware(machine) → hwState
- machine.hasFault() / machine.maintenanceFlags
- HAL.checkMaintenanceState(machine, transposerAddr, side)
- machine.parseHealth(sensorLines)
- machine.updateHardwareState(progress)
- Completion gate: machine.parseHealth(sensorLines)
- Staleness: manifest.isStale()

### CLEANUP (runs every tick, not gated)
- _clearLaneIfaceAndDb() — targeted + full wipe
- HAL.drainInventory(transposer, push, return_)
- machine.releaseJob() / machine.clearFault()
- manifest.unbindHardware()
- manifest.updateState("COMPLETED" or "FAULTED")
- report.clearFault()
- Remove from activeJobs

## Dead / Unused Code

| Location | Item | Verdict |
|----------|------|---------|
| buffering.lua:28 | context.autoCraftChecker = context.autoCraftChecker | **Removed** — self-assignment no-op |
| MachineNode:toMaintenanceReport() | String formatter | Never called in phase code. Only summarize() could reach it, but it calls toTelemetry() instead |
| MachineNode:getActiveJob() | Returns self.activeJob | Only consumed in toTelemetry(). Alive if telemetry is active |
| TransferringPhase:_scheduleCoroutine() | Gated behind useCoroutineTransfer (default false) | Listed as "not yet implemented" — alive but dormant |
| processing.lua getProxy().isMachineActive() | Was 15 lines | **Removed** — now uses hwState.active from poll |

## Simplifications Considered

| Location | Observation | Decision |
|----------|------------|----------|
| allocating.lua refreshHealth() | 5-line wrapper around hal:quickHealthCheck() | Keep — clear delegation point |
| exec_broker.lua:369-443 | 75-line do block constructing phase modules | Keep — DI wiring is explicit and testable |
| transferring.lua _transferForJob() | 230 lines, 6 sequential if/STEP blocks | Keep — flat structure is debuggable |
| checkMaintenanceState vs quickHealthCheck | Two health probes with similar internals | Keep separate — allocating needs fast, processing needs thorough |
| MachineNode:parseHealth() | Used by both allocating (via quickHealthCheck) and processing | Good — single source of truth for sensor parsing |

## Abstractions Worth Extracting

| Candidate | Current Location | Lines | Notes |
|-----------|-----------------|-------|-------|
| Broker persistence | exec_broker.lua (_savePersistence through _restoreManifest) | ~100 | Self-contained. Inject queue/activeJobs/machines |
| readProgressBar() | processing.lua:86-109 | 24 | Used only by processing phase. Too small to warrant extraction |
| HAL.quickHealthCheck | hal/maintenance.lua | 47 | Already extracted. Clean boundary |

## HAL Method Inventory

| Method | Used By | Notes |
|--------|---------|-------|
| getProxy | All phases via quickHealthCheck, pollMachineHardware | Cached with TTL |
| quickHealthCheck | AllocatingPhase | New — hardware flags + sensor text |
| pollMachineHardware | ProcessingPhase | Returns hwState, records faults |
| checkMaintenanceState | ProcessingPhase | Full check: EU, ghost items, jams |
| storeNetworkEntry | TransferringPhase (store step) | |
| configureInterfaceStocking | TransferringPhase (stock step) | |
| configureFluidExport | TransferringPhase (stock step) | |
| checkInterfaceStocked | TransferringPhase (wait step) | |
| drainInventory | TransferringPhase (pull), CleanupPhase | |
| clearInterfaceSlot | TransferringPhase, CleanupPhase | |
| clearFluidExport | TransferringPhase, CleanupPhase | |
| clearDatabaseSlot | TransferringPhase, CleanupPhase | |
| pulseRedstoneLock | TransferringPhase (clear step) | |
| getMEContents | BufferingPhase (bufferFeeder) | |
| requestCraft | BufferingPhase (auto-crafting) | |
| getCapabilities/hasCapability | checkMaintenanceState | |
| parseSensorData | checkMaintenanceState | Advisory-only |
| invalidateCache | pollMachineHardware, refreshMachines | |

## MachineNode Method Inventory

| Method | Used By | Notes |
|--------|---------|-------|
| parseHealth | Allocating (via quickHealthCheck), Processing | Pure Lua, no OC deps |
| updateHealth | Allocating (via quickHealthCheck) | Caches sensor parse result |
| isHealthy | Allocating | Threshold >= 80 |
| getHealthScore | Allocating | 0-100 |
| getHealthIssues | Allocating | Issue codes array |
| isAvailable | Allocating | Checks status == AVAILABLE |
| lock / bindJob | Allocating | AVAILABLE→LOCKED→PROCESSING |
| releaseJob | Cleanup | PROCESSING→AVAILABLE |
| hasFault / clearFault | Allocating, Processing, Cleanup | |
| recordFault | pollMachineHardware | *→FAULTED |
| updateHardwareState | pollMachineHardware | Caches progress |
| toTelemetry | exec_broker telemetry | |
```
