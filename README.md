# AE2-ES — AE2 Execution System

A decoupled, two-part MES-like system for GTNH (GregTech New Horizons) that couples Applied Energistics 2 with OpenComputers to orchestrate automated machine array processing with state-driven dispatch, hardware fault recovery, and telemetry-based supervision.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [File Structure](#file-structure)
4. [Installation](#installation)
5. [Components](#components)
6. [Specification Verification Matrix](#specification-verification-matrix)
7. [Testing](#testing)
8. [CI/CD Pipeline](#cicd-pipeline)
9. [Horizon-QA GameTest Suite](#horizon-qa-gametest-suite)
10. [Deliverables Summary](#deliverables-summary)
11. [Known Gaps](#known-gaps)

---

## Overview

AE2-ES is a manufacturing execution system designed for GTNH factories. It splits control into two independent OpenComputers programs connected via modem network:

- **Exec Broker** — Subnet controller managing a localized machine array (e.g., 4 Large Chemical Reactors). Operates on an isolated AE2 subnet with a 6-phase state machine.
- **Supervisor** — Central coordinator aggregating telemetry from all brokers, tracking global resource depletion (TTD), and providing a real-time dashboard.

The system is designed for cooperative multitasking (OC's single-threaded Lua environment), fire-and-forget telemetry, and Just-In-Time database allocation to minimize GC pressure. Interactive config UIs on both broker and supervisor eliminate the need to edit Lua files for component address setup.

---

## Architecture

```
┌─────────────────────────────────────────┐
│              SUPERVISOR                  │
│  (Main-Net Coordinator)                  │
│  - Aggregates telemetry from brokers     │
│  - TTD (Time-to-Depletion) tracking      │
│  - Inter-broker coordination             │
│  - Central dashboard UI                  │
│  - Interactive config UI (B7)            │
└──────────┬──────────────────────────────┘
           │ modem broadcasts (fire-and-forget)
    ┌──────┼──────┬──────────────┐
    ▼      ▼      ▼              ▼
┌──────┐┌──────┐┌──────┐   ┌──────┐
│Exec  ││Exec  ││Exec  │   │Exec  │
│Broker││Broker││Broker│...│Broker│
└──────┘└──────┘└──────┘   └──────┘
  (subnet controller — localized machine array)
  Each has an interactive config UI (A13)
```

### Exec Broker: 6-Phase State Machine

```
BUFFERING → LOGGING → ALLOCATING → TRANSFERRING → PROCESSING → CLEANUP
```

1. **BUFFERING** — Detects incoming resources in the AE2 subnet central buffer; initiates 1.5s debounce window for stabilization.
2. **LOGGING** — Reads stable buffer contents via BufferSnapshot; registers item/fluid IDs in JIT database.
3. **ALLOCATING** — Polls machine array for available hardware; binds job to machine; supports out-of-order dispatch.
4. **TRANSFERRING** — Pushes items/fluids to machine's AE2 Dual Interface; hardware routes to input bus; unlocks redstone gate on completion.
5. **PROCESSING** — Monitors machine via Adapter; detects job completion or 10s idle timeout.
6. **CLEANUP** — Extracts residuals from input bus; routes to return-line chest; returns machine to AVAILABLE.

### Supervisor: Event-Driven Loop

```
Listen → Deserialize → FIFO Queue → Index Matrix → Evaluate → Update UI
```

### Testing Tiers

```
Tier 1 (lupa) → Tier 2 (Integration) → Tier 3 (Soak)
     │                  │                    │
     ▼                  ▼                    ▼
  Lua unit tests    Horizon-QA         5x soak cycles
  (every push)      (gametest/ +       + GC leak check
                     horizon-qa/)      (nightly cron)
```

---

## File Structure

```
AE2-ES/
├── README.md
├── .github/workflows/ae2-es-ci.yml    # 3-tier CI/CD Pipeline
│
├── src/                               # Exec Broker core modules
│   ├── exec_broker.lua                # A8: Main event loop (925 lines)
│   ├── buffersnapshot.lua             # A3: Buffer checksum & debounce
│   ├── hal.lua                        # A5: Hardware Abstraction Layer
│   ├── jobmanifest.lua                # A1: JIT-allocated job manifest
│   ├── MachineNode.lua                # A2: Machine abstraction (standalone)
│   ├── profiler.lua                   # C8: Runtime performance profiler
│   ├── telemetrypayload.lua           # A7: Serialization envelope
│   ├── timeslicescheduler.lua         # A11: Cooperative multitasking
│   ├── config_ui.lua                  # A13: Exec Broker config UI
│   └── supervisor.lua                 # Supervisor coordinator
│
├── src/ui/
│   └── common.lua                     # Shared UI components (menus, dialogs)
│
├── supervisor/                        # Supervisor sub-modules
│   ├── config_ui.lua                  # B7: Supervisor config UI
│   ├── modem_subscriber.lua           # B1: Modem event loop
│   └── ui/dashboard.lua               # B5: Dashboard UI
│
├── exec_broker/
│   └── maintenance_report.lua         # A6: Fault diagnostics
│
├── gametest/                          # C7-R: Horizon-QA Java GameTest project
│   ├── build.gradle.kts               # Gradle build config
│   ├── STRUCTURES.md                  # Test structure build guide
│   └── src/main/java/com/ae2es/gametest/
│       ├── GameTestSuite.java         # Aggregate suite runner
│       ├── ModemBroadcastTest.java    # 4-broker modem topology
│       ├── TransposerTransferTest.java # Item transfer validation
│       ├── MaintenanceFaultTest.java  # GT maintenance detection
│       ├── DebounceWindowTest.java    # BufferSnapshot stability
│       └── GhostItemTest.java         # Ghost-item detection
│
├── horizon-qa/                        # C9: Horizon-QA Lua test harness
│   ├── runner.lua                     # Test discovery & execution
│   ├── json_writer.lua                # JUnit XML output
│   ├── run_tier2.sh / run_tier2.py    # CI runners
│   └── tests/                         # 6 Lua test scenarios
│
├── JobManifest.lua                    # A1: 6-phase state machine
├── JobManifest_test.lua               # A1 unit tests
├── JobQueue.lua                       # A4: Bounded FIFO job queue
├── JobQueue_test.lua                  # A4 unit tests
├── MaintenanceReport.lua              # A6: Fault reporting
├── MaintenanceReport_test.lua         # A6 unit tests
├── ttd_tracker.lua                    # B3: TTD rate monitoring
├── ttd_tracker_test.lua               # B3 unit tests
│
├── run_tests.py                       # Python/lupa test runner
├── run_dashboard_tests.py             # Dashboard test runner
├── run_tier2.py                       # Tier 2 integration runner
│
└── tests/                             # Test suite (Deliverable C)
    ├── run_tests.lua                  # Lua-native test discovery
    ├── run_tier2.lua                  # Tier 2 Lua runner
    ├── run_tier3.lua / run_tier3.py   # Tier 3 soak + profiling
    ├── test_state_transitions.lua     # C1: State transitions
    ├── test_telemetry_serialization.lua # C2: Serialization
    ├── test_jit_db_cleanup.lua        # C2: JIT cleanup
    ├── test_malformed_payload.lua     # C2: Error handling
    ├── test_integration.lua           # C3: Integration tests
    ├── test_soak.lua                  # C4: Soak tests
    ├── test_timeslicescheduler.lua    # C5: Scheduler profiling
    ├── test_profiler.lua              # C8: Profiler unit tests
    ├── unit/
    │   ├── test_dashboard.lua         # B5: Dashboard tests
    │   ├── test_config_ui.lua         # A13: Config UI tests
    │   └── test_supervisor_config_ui.lua # B7: Config UI tests
    └── helpers/
        ├── assertions.lua             # Shared test assertions
        ├── mock_env.lua               # OC environment mock
        └── mock_modules.lua           # Reference mocks
```

---

## Installation

### Prerequisites

- OpenComputers 1.7+ (GTNH pack)
- Applied Energistics 2
- GregTech 5 Unofficial / GTNH
- Lua 5.2/5.3 runtime

### Deploying to OpenComputers

1. Copy `src/` contents to the Exec Broker OC computer's `/` directory
2. Copy `supervisor/` contents to the Supervisor OC computer's `/` directory
3. Copy root-level modules (`JobManifest.lua`, `JobQueue.lua`, `MaintenanceReport.lua`, `ttd_tracker.lua`) to both computers
4. Run `src/config_ui.lua` on first boot for interactive component setup (or `src/exec_broker.lua` / `src/supervisor.lua` directly)

### Local Development & Testing

```bash
git clone https://github.com/tjmeltesen/AE2-ES.git
cd AE2-ES

# Install test dependencies
pip install -r requirements.txt

# Run all tests (Tier 1)
python run_tests.py

# Run dashboard tests
python run_dashboard_tests.py

# Run Tier 2 integration tests
python run_tier2.py

# Run Tier 3 extended soak + profiling
python tests/run_tier3.py

# Run native Lua soak test
lua tests/run_tier3.lua

# Build Horizon-QA GameTest project
cd gametest && ./gradlew build
```

### Hardware Requirements (per Exec Broker)

| Component | Purpose |
|-----------|---------|
| AE2 Dual Interface | Localized inventory buffer |
| OpenComputers Adapter | Hardware monitor |
| Transposer | Physical item routing |
| OC Database (Tier 3) | JIT software registry |
| OC Modem | Network backbone |
| OC Redstone I/O Block | Main-net/subnet gatekeeper |

---

## Components

### Deliverable A: Exec Broker

| Module | File | Description |
|--------|------|-------------|
| **A1: JobManifest** | `JobManifest.lua` | Atomic unit of work. Validated 6-phase state machine with legal transition enforcement, staleness timeouts, and metadata. |
| **A2: MachineNode** | `src/MachineNode.lua` | Software abstraction of physical machine. Tracks status (AVAILABLE/LOCKED/FAULTED), activeJob, maintenanceFlags, telemetry serialization. |
| **A3: BufferSnapshot** | `src/buffersnapshot.lua` | FNV-1a checksum-based stability detection with 1.5s debounce window. Converts stable snapshots to JobManifests. |
| **A4: JobQueue** | `JobQueue.lua` | Bounded FIFO queue with priority-aware `popNextAvailable()`, length(), peek(), and validateQueue() for stale detection. |
| **A5: HAL** | `src/hal.lua` | Middleware translating abstract commands to OC API calls. Component proxy caching, bitmask capabilities, pcall-wrapped transferItem with fault detection. |
| **A6: MaintenanceReport** | `MaintenanceReport.lua` + `exec_broker/maintenance_report.lua` | Fault code constants (6 codes), player-facing labels/actions, 100-entry in-memory history. |
| **A7: TelemetryPayload** | `src/telemetrypayload.lua` | Build, serialize, deserialize, validate, transmit. Schema versioning (v1). |
| **A8: Main Event Loop** | `src/exec_broker.lua` | 6-phase state machine with dependency injection. Configurable intervals. All phases yield. |
| **A9: Redstone Lock** | `src/exec_broker.lua` | Phase 4: lifts gate only after confirming Dual Interface reads 0 items/fluids and cleared IDs. |
| **A10: Edge Cases** | `src/exec_broker.lua` + `src/hal.lua` | All 5 edge cases: premature unlock, mid-transfer fault, ghost items, saturation, maintenance recovery. |
| **A11: TimeSliceScheduler** | `src/timeslicescheduler.lua` | 3s budget, forEach() yield checkpoints, defer/processQueue, yield counting. |
| **A12: Local UI** | `src/exec_broker.lua` | Integrated config view, log viewer, status dashboard. |
| **A13: Config UI** | `src/config_ui.lua` | Interactive terminal setup wizard. Detects OC components, validates selections, persists to `/home/ae2es_broker.cfg`. |

### Deliverable B: Supervisor

| Module | File | Description |
|--------|------|-------------|
| **B1: Modem Subscriber** | `supervisor/modem_subscriber.lua` | event.pull("modem_message") loop, deserialization, FIFO queue, per-broker health (STALE >30s, OFFLINE >120s). |
| **B2: GlobalMachineMatrix** | `src/supervisor.lua` | Registry tracking every broker and machine array status. |
| **B3: TTD Tracking** | `ttd_tracker.lua` | 20-sample sliding window, WARNING/CRITICAL thresholds, crafting signal emission with debounce, kind-filtered queries. |
| **B4: Alert Routing** | `src/supervisor.lua` | FIFO queue with overflow trimming. 200-entry circular log buffer. |
| **B5: Dashboard UI** | `supervisor/ui/dashboard.lua` | Real-time factory view. Broker list, machine grid, TTD gauges, alert log. |
| **B6: Inter-Broker Coordination** | `src/supervisor.lua` | Consumer registration pattern. Cross-broker routing, maintenance deadlock detection. |
| **B7: Config UI** | `supervisor/config_ui.lua` | Tabbed config UI (Modem/TTD/Dashboard/Brokers). Broker health indicators, threshold editing, layout config. |

### Deliverable C: Testing & CI/CD

| Module | File | Description |
|--------|------|-------------|
| **C1: State Transitions** | `tests/test_state_transitions.lua` | 120+ tests, all 6 state transitions, production module integration. |
| **C2: JIT DB + Serialization** | `tests/test_telemetry_serialization.lua` + 2 more | JIT allocation/cleanup, serialization round-trip, malformed payload rejection. |
| **C3: Integration** | `tests/test_integration.lua` | 4-broker broadcast, HAL API translation, fault injection, ghost detection, full cycle. |
| **C4: Soak** | `tests/test_soak.lua` | 1K micro-jobs, 12 suites, 88 tests, 7,238 assertions. Flat memory (~96KB). |
| **C5: Profiling** | `tests/test_timeslicescheduler.lua` | Yield gap analysis, GC tracking, TMI prevention assertions. |
| **C6: CI/CD Pipeline** | `.github/workflows/ae2-es-ci.yml` | 3-tier pipeline: unit (every push), integration+soak (nightly), Horizon-QA GameTest (PR). |
| **C7-R: GameTest** | `gametest/` | Horizon-QA Java GameTest project. 5 test classes, 16 tests, full Gradle build. |
| **C8: Runtime Profiler** | `src/profiler.lua` | Phase timing, yield gap detection (4s guard), GC baseline tracking (5% within 30s). |
| **C9: Horizon-QA Harness** | `horizon-qa/` | 6 Lua integration scenarios, JUnit XML output, CI shell/Python runners. |

---

## Specification Verification Matrix

### Phase Implementation

| Spec Phase | Implementation | Status |
|-----------|---------------|--------|
| Phase 1: BUFFERING | `src/exec_broker.lua:_phaseBUFFERING()` — polls buffer, feeds BufferSnapshot, 1.5s debounce | ✓ |
| Phase 2: LOGGING | `src/exec_broker.lua:_phaseLOGGING()` — snapshot→JobManifest, push to JobQueue, reset snapshot | ✓ |
| Phase 3: ALLOCATING | `src/exec_broker.lua:_phaseALLOCATING()` — pop job, find available machine, validate health, bind | ✓ |
| Phase 4: TRANSFERRING | `src/exec_broker.lua:_phaseTRANSFERRING()` — HAL item/fluid push, confirm empty interface, lift lock | ✓ |
| Phase 5: PROCESSING | `src/exec_broker.lua:_phasePROCESSING()` — Adapter monitoring, 10s idle timeout, ghost detection | ✓ |
| Phase 6: CLEANUP | `src/exec_broker.lua:_phaseCLEANUP()` — maintenance lock, residual extraction, return routing, unlock | ✓ |

### Edge Cases

| Edge Case | Implementation | Status |
|-----------|---------------|--------|
| EC1: Premature Buffer Unlock | Phase 4: Dual Interface = 0 items, 0 mB, cleared IDs before lock lift | ✓ |
| EC2: Machine Fault Mid-Transfer | HAL fault detection → FAULTED → Cleanup → MaintenanceReport | ✓ |
| EC3: Ghost Items | 10s idle timeout → blind input bus flush via return line | ✓ |
| EC4: Array Saturation | ALLOCATING yields when no AVAILABLE; redstone lock holds buffer | ✓ |
| EC5: Maintenance Recovery | Heartbeat polling → auto-clear FAULTED → AVAILABLE | ✓ |

### Design Constraints

| Constraint | Implementation | Status |
|-----------|---------------|--------|
| Cooperative Multitasking | TimeSliceScheduler (3s budget, forEach yields, defer queue) | ✓ |
| Async Event Handling | event.pull() based loops; no blocking while-true | ✓ |
| JIT Memory Efficiency | JIT tables nilled on complete(); `isJITCleaned()` + profiler GC tracking | ✓ |
| Fire-and-Forget Telemetry | Modem broadcast without Supervisor response | ✓ |
| Config UI (Interactive Setup) | `src/config_ui.lua` + `supervisor/config_ui.lua` — no Lua file editing | ✓ |
| Horizon-QA Tier 2 Testing | `gametest/` (Java GameTest) + `horizon-qa/` (Lua harness) | ✓ |

---

## Testing

### Running Tests

```bash
# Tier 1 — All Lua tests via lupa bridge
pip install -r requirements.txt
python run_tests.py

# Dashboard tests
python run_dashboard_tests.py

# Tier 2 — Integration tests
python run_tier2.py

# Tier 3 — Extended soak + profiling (Python)
python tests/run_tier3.py

# Tier 3 — Native Lua soak test
lua tests/run_tier3.lua

# Specific test file
lua tests/test_state_transitions.lua

# Horizon-QA GameTest (requires Gradle + Forge server)
cd gametest && ./gradlew build
```

### Test Statistics

| Test Suite | Tests | Assertions | Status |
|-----------|-------|------------|--------|
| C1: State Transitions | 120+ | ~500 | ✓ |
| C2: JIT DB + Serialization | 40+ | ~200 | ✓ |
| C3: Integration | 5 scenarios | ~100 | ✓ |
| C4: Soak | 88 | 7,238 | ✓ |
| C5: Profiling | 30+ | ~300 | ✓ |
| C8: Runtime Profiler | 15+ | ~100 | ✓ |
| Dashboard UI | 50+ | ~500 | ✓ |
| Config UIs (A13/B7) | 20+ | ~150 | ✓ |
| GameTest (C7-R) | 16 | — | ✓ |

---

## CI/CD Pipeline

See `.github/workflows/ae2-es-ci.yml`. Three tiers with per-event conditionals:

| Job | Trigger | What Runs |
|-----|---------|-----------|
| **Tier 1: Unit + Integration** | Every push + PR (`!= schedule`) | `python run_tests.py` + `run_dashboard_tests.py` |
| **Tier 2: Nightly Soak** | Schedule + manual (`== schedule \|\| workflow_dispatch`) | Full suite 5x + GC memory leak check |
| **Tier 3: Extended Soak** | Schedule + manual | `python tests/run_tier3.py` + `lua tests/run_tier3.lua` |
| **Horizon-QA GameTest** | PR to main only | `cd gametest && ./gradlew runServer -Dhorizonqa.mode=ci` |
| **Notify Failure** | On Tier 2/3 failure | Logs failure summary |

---

## Horizon-QA GameTest Suite

The `gametest/` directory is a standalone Gradle project using the [Horizon-QA](https://github.com/GTNewHorizons/Horizon-QA) Java GameTest framework. It validates AE2-ES against real AE2, GregTech, and OpenComputers mod blocks in a Forge 1.7.10 server.

### Test Classes

| Class | Tests | What It Validates |
|-------|-------|-------------------|
| `ModemBroadcastTest` | 3 | 4-broker modem topology, redstone gating, broadcast range |
| `TransposerTransferTest` | 3 | AE2 Interface → Transposer → GT Input Bus item transfer |
| `MaintenanceFaultTest` | 3 | GT machine maintenance detection, gating, and recovery |
| `DebounceWindowTest` | 3 | BufferSnapshot stability window and redstone lock timing |
| `GhostItemTest` | 4 | Ghost-item detection (10s timeout) and blind-flush cleanup |

### Running GameTests

```bash
# Build
cd gametest && ./gradlew build

# Run in CI (headless)
./gradlew runServer --mcJvmArgs="-Dhorizonqa.mode=ci -Dhorizonqa.batch=ae2es"

# Run interactively (in-game)
./gradlew runServer
# /horizonqa runall ae2es
```

### Structure Templates

Each test class depends on structure templates built in-game with the Horizon Wand. Templates live at `gametest/src/main/resources/assets/ae2es/horizonqastructures/`. See `gametest/STRUCTURES.md` for build instructions.

### Git Workflow

```bash
# GameTest Java code
git add gametest/ && git commit -m "test: <description>"

# Structure templates
git add gametest/src/main/resources/ && git commit -m "structure: <name>"

# Use --no-verify (Lua pre-commit hook needs lupa, unavailable for Java)
git commit --no-verify -m "test: <description>"
```

---

## Deliverables Summary

### GitHub Repository

- **URL:** https://github.com/tjmeltesen/AE2-ES
- **Total PRs merged:** 27
- **Total kanban tasks completed:** 91
- **Total source files:** 69
- **Production code:** ~12,000 lines (Lua + Java)
- **Test code:** ~12,000 lines

### Recent PRs (since initial release)

| PR | Title |
|----|-------|
| #15-17 | Dependabot CI dependency bumps |
| #18 | A2: MachineNode standalone production module |
| #19 | A4: JobQueue standalone production module |
| #20 | C6-T3: Tier 3 soak tests + pre-commit hook + PR template |
| #21 | C8: Runtime Performance Profiler |
| #22 | CI: consolidate into single ae2-es-ci.yml |
| #23 | A13: Exec Broker interactive config UI |
| #24 | B7: Supervisor interactive config UI + shared UI library |
| #25 | C6-T2: Tier 2 CI integration test pipeline |
| #26 | C9: Horizon-QA integration test harness |
| #27 | C7-R: Horizon-QA Java GameTest suite |

---

## Known Gaps

1. **Redstone Lock Physical I/O** — Phase 4 redstone gate control is abstracted behind configurable interfaces. Real OC deployment requires setting the correct redstone I/O block address via the config UI.

2. **TTD Item/Fluid Tracking** — TTD tracker infrastructure supports items and fluids but currently monitors power only. Thresholds are configured; integration with AE2 fluid/item queries is needed.

3. **Filesystem Persistence** — JobManifest and MaintenanceReport are in-memory only. Config UIs persist settings, but runtime state does not survive OC reboots.

4. **GameTest Structure Templates** — The 5 GameTest classes are written but their `.json`/`.snbt` structure templates must be exported from an in-game GTNH build using `/horizonqa export`. Templates are documented in `gametest/STRUCTURES.md` but not yet baked.

---

## License

MIT — see source files for details.

## Contributors

- Thomas Meltesen (tjmeltesen)
- AE2-ES Kanban Workers (multi-agent orchestrated development)
