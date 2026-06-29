# AE2-ES Architecture Guide

> A guide for understanding, maintaining, and extending the AE2 Execution System.

---

## What is AE2-ES?

AE2-ES is a Lua program that runs on OpenComputers inside Minecraft (GT New Horizons modpack). It automates GregTech machine processing by acting as a **broker**: it watches a central storage buffer, detects when items are available, and dispatches them to processing machines via the Applied Energistics 2 (AE2) network.

Think of it like a factory foreman:
1. Watches the input warehouse (central buffer)
2. When items arrive and the supply stabilizes, creates a work order (job)
3. Assigns the job to an available machine
4. Uses AE2 to deliver materials to the machine
5. Waits for the machine to finish
6. Cleans up and starts the next job

---

## Directory Structure

```
AE2-ES/
  src/
    exec_broker.lua        ← Main event loop (6-phase state machine)
    hal.lua                ← Hardware Abstraction Layer (talks to OC components)
    BufferSnapshot.lua     ← Stability debouncing for buffer contents
    JobManifest.lua        ← Atomic unit of work (the "work order")
    MachineNode.lua        ← Machine state tracking (locked/processing/faulted)
    JobQueue.lua           ← Priority queue for pending jobs
    MaintenanceReport.lua  ← Fault tracking per machine
    telemetrypayload.lua   ← Network telemetry broadcasts
    broker_logger.lua      ← Diagnostic logging
    config_ui.lua          ← Interactive config wizard
    supervisor.lua         ← Telemetry receiver (separate computer)
  tests/
    test_integration.lua   ← Full-system integration tests
    test_state_transitions.lua  ← State machine validation
    ocemu_test_suite.lua   ← OC emulator tests (CI-safe)
    helpers/               ← Mock components for testing
```

---

## The Big Picture: Data Flow

```
  ┌──────────────┐     poll      ┌──────────────────┐
  │ Item Buffer  │──────────────→│  bufferFeeder()   │
  │ (drawers)    │               │  reads inv ctrl   │
  └──────────────┘               └────────┬─────────┘
                                          │ {items, fluids}
  ┌──────────────┐     poll              ↓
  │ Fluid Buffer │──────────────→┌──────────────────┐
  │ (hatch)      │               │ BufferSnapshot   │
  └──────────────┘               │ stability check  │
                                 └────────┬─────────┘
                                          │ stable? → convert
                                          ↓
                                 ┌──────────────────┐
                                 │   JobManifest    │ → JobQueue
                                 │   (work order)   │
                                 └────────┬─────────┘
                                          │ allocate machine
                                          ↓
  ┌──────────────────────────────────────────────────────┐
  │                  EXEC BROKER                          │
  │                                                       │
  │  BUFFERING → LOGGING → ALLOCATING → TRANSFERRING     │
  │                                          ↓            │
  │       CLEANUP  ←──────────────────  PROCESSING        │
  └──────────────────────────────────────────────────────┘
                    │                    │
                    ↓                    ↓
  ┌──────────────────┐     ┌──────────────────┐
  │  Dual Interface  │     │  GT Machine      │
  │  (AE2 stocking)  │     │  (processing)    │
  └──────────────────┘     └──────────────────┘
```

---

## Module 1: exec_broker.lua — The 6-Phase State Machine

**File:** `src/exec_broker.lua`  
**Role:** Orchestrator. Owns the main event loop. Delegates to all other modules.

### Constructor

```lua
local broker = ExecBroker.new(config)
```

**Required config fields:**

| Field | Type | Purpose |
|-------|------|---------|
| `brokerId` | string | Unique name for this broker (e.g. "LCR-arr") |
| `machines` | array | `[{laneId, machineAddr}]` — machines this broker manages |
| `machineTransposers` | table | `{[laneId] = {dualInterface, transposerAddr, pull, push, return_}}` — per-lane hardware config |
| `itemBufferAddr` | string | UUID of the item buffer (inventory controller) |
| `fluidBufferAddr` | string | UUID of the fluid buffer (tank controller) |
| `databaseAddr` | string | UUID of the OC Database component |

**Optional fields (defaults shown):**

| Field | Default | Purpose |
|-------|---------|---------|
| `pollInterval` | 0.5 | Seconds between buffer polls |
| `heartbeatInterval` | 2.0 | Seconds between telemetry broadcasts |
| `debounceWindow` | 1.5 | Seconds of stability required before creating a job |
| `queueSize` | 64 | Max pending jobs |

### The 6 Phases

The broker is always in exactly one phase. Each `tick()` call advances the state machine.

#### Phase 1: BUFFERING (`_phaseBUFFERING`)
```
What it does: Polls the central buffer, waits for contents to stabilize.
Why:         If items are still arriving, we don't want to snapshot a partial set.
How:         bufferFeeder() → BufferSnapshot:update() → check stable?
Output:      If stable → LOGGING.  If not → stay BUFFERING.
```

**Key detail:** The bufferFeeder is auto-created from `itemBufferAddr`/`fluidBufferAddr` using `component.proxy()`. It reads the inventory controller (for items) and tank controller (for fluids) with pcall wrappers. Each item is captured as `{name, label, size, damage, nbt}`.

#### Phase 2: LOGGING (`_phaseLOGGING`)
```
What it does: Converts the stable snapshot into a JobManifest and pushes to queue.
Why:         This is a pass-through — separates "detect stable buffer" from "act on it."
Output:      ALLOCATING (if job was queued) or BUFFERING (if something went wrong).
```

#### Phase 3: ALLOCATING (`_phaseALLOCATING`)
```
What it does: Takes the next job from the queue, finds an available machine, locks it.
Why:         Serializes access to machines — only one job per machine at a time.
How:         Pops queue → iterates machineList → first isAvailable() → lock() → bindJob()
Output:      TRANSFERRING (transfer started) or CLEANUP (transfer faulted).
```

#### Phase 4: TRANSFERRING (`_phaseTRANSFERRING`)
```
What it does: Delivers items from central buffer to the machine.
Why:         This is where the AE2 transfer model lives.
How:         6-step sub-pipeline per job:

  store → stock → wait → pull → verify → clear → PROCESSING

  1. store:  Write item/fluid refs to Database (JIT, max 9 slots)
  2. stock:  Configure Dual Interface to pull from Database
  3. wait:   Poll interface until AE2 delivers the items
  4. pull:   Transposer: Dual Interface → Machine Input Bus
  5. verify: Check interface is empty, re-pull if needed
  6. clear:  Clear interface config + Database slots

  Fluids: setFluidInterfaceConfiguration (fire-and-forget, conduit auto-pulls)
```

**Important:** The transposer is ONLY used for two local hops:
- `ifaceSide → inputSide` (during TRANSFERRING, step 4)
- `inputSide → returnSide` (during CLEANUP, extracting leftovers)

AE2 handles the central-buffer-to-interface leg automatically through its network pull mechanism. We never move items directly from the buffer to the machine — we tell AE2 what to stock, and AE2 does the heavy lifting.

#### Phase 5: PROCESSING (`_phasePROCESSING`)
```
What it does: Waits for the machine to finish its recipe.
Why:         We need to know when the machine is done before cleanup.
How:         machine:pollHardware() → check hasFault() → check isMachineActive()
             Detection: machine inactive for 3+ ticks → done.
             Timeout:   manifest:isStale() → fault the job.
Output:      CLEANUP (when all jobs complete) or stay PROCESSING.
```

#### Phase 6: CLEANUP (`_phaseCLEANUP`)
```
What it does: Extract leftovers, release the machine, update stats.
Why:         Return the machine to AVAILABLE so the next job can use it.
How:         1. Transposer: Input Bus → Return Chest (leftover items)
             2. machine:releaseJob()
             3. manifest:unbindHardware()
             4. Update stats (jobsCompleted / jobsFaulted / totalJobTime)
Output:      ALLOCATING (if queue has more jobs) or BUFFERING (idle).
```

### The Tick Loop

```lua
broker:tick()   -- call once per event loop iteration
```

Each tick:
1. Polls buffer via bufferFeeder (throttled by pollInterval)
2. Updates BufferSnapshot with new poll data
3. If snapshot stable → creates JobManifest → pushes to queue
4. Advances the phase machine based on current phase
5. Sends telemetry (throttled by heartbeatInterval)

**Cooperative multitasking:** Between ticks, the broker yields via `event.pull(pollInterval)`. This lets OpenComputers handle other events (modem messages, redstone changes, etc.).

### How to Add a New Phase

1. Add the phase name to `ExecBroker.PHASES` (line 25)
2. Add a `_phaseYOURPHASE()` method
3. Add a branch in `tick()` (line ~945) to dispatch to it
4. Add the phase to VALID_TRANSITIONS in JobManifest.lua

---

## Module 2: hal.lua — Hardware Abstraction Layer

**File:** `src/hal.lua`  
**Role:** All OC component interaction goes through HAL. No other module calls `component.proxy()` or `transposer.transferItem()` directly.

### Why HAL Exists

Without HAL, every module would call OC component APIs directly. This causes three problems:
1. **Testability** — you can't mock OC components in unit tests
2. **Error handling** — every caller needs its own pcall wrappers
3. **Side mapping** — side constants (north=0, south=1, etc.) would be hardcoded everywhere

HAL solves all three:
- Tests inject MockModules.HAL with recording stubs
- All OC calls go through pcall with structured error messages
- Side mapping is centralized and configurable

### Constructor

```lua
local hal = HAL.new({
  sideMap = {
    inputBus    = 0,   -- side number where machine input bus sits
    itemBuffer  = 0,   -- side where item buffer (drawer) is
    fluidBuffer = 1,   -- side where fluid buffer (hatch) is
    dualInterface = 2, -- transposer side facing the Dual Interface
    returnChest = 4,   -- transposer side facing return chest
    fluidExport = 5,   -- interface side for fluid conduit
  },
  cacheTTL = 300,      -- seconds before refreshing a component proxy
})
```

### Public API

#### Component Proxy Management

| Method | Purpose |
|--------|---------|
| `getProxy(address)` | Get cached OC component proxy. Creates one if needed. Returns nil on failure. |
| `invalidateCache(address)` | Force-refresh a proxy (call after disconnect errors) |

#### Side Resolution

| Method | Purpose |
|--------|---------|
| `resolveSide(role)` | Map logical role name → side number. e.g. `resolveSide("inputBus")` → `0` |
| `setSideMapping(role, side)` | Override a side mapping at runtime |

#### Inventory Operations

| Method | Signature | Purpose |
|--------|-----------|---------|
| `performInventoryTransfer` | `(fromSide, toSide, count?, fromSlot?, toSlot?)` | Move items between adjacent inventories via transposer |
| `drainInventory` | `(fromSide, toSide)` | Transfer ALL items from one inventory to another, slot by slot |
| `getInventoryContents` | `(side)` | Snapshot all items in an inventory |
| `checkSlotCount` | `(side, slot)` | Count items in a specific slot (handles GTNH .size quirk) |

#### Fluid Operations

| Method | Purpose |
|--------|---------|
| `performFluidTransfer(fromSide, toSide, count?, fromTank?)` | Transfer fluid between tanks via transposer |
| `getTankContents(side)` | Snapshot all fluids in tanks |

#### Database Operations (JIT — max 9 slots)

| Method | Purpose |
|--------|---------|
| `storeDatabaseEntry(dbAddress, slot, name, damage, nbt)` | Write an item/fluid reference to Database |
| `clearDatabaseSlot(dbAddress, slot)` | Clear a single Database slot |

#### ME Interface Configuration

| Method | Purpose |
|--------|---------|
| `configureInterfaceStocking(ifaceAddress, slot, dbAddress, dbSlot, count)` | Tell interface to stock N items from a Database reference |
| `clearInterfaceSlot(ifaceAddress, slot)` | Clear an interface config slot |
| `configureFluidExport(ifaceAddress, side, dbAddress, dbSlot)` | Tell interface to export fluid on a side |
| `clearFluidExport(ifaceAddress, side)` | Clear fluid export config |

#### Maintenance

| Method | Purpose |
|--------|---------|
| `checkMaintenanceState(machineNode)` | Comprehensive health check → structured health report |

### GTNH Quirks Handled by HAL

1. **Missing `.size` on stacks:** In GTNH, `transposer.getStackInSlot()` sometimes returns a table without a `.size` field. HAL falls back to `transposer.getSlotStackSize()`.
2. **Proxy caching:** `component.proxy()` is expensive. HAL caches proxies for `cacheTTL` seconds.
3. **TMI errors:** HAL yields (`os.sleep(0)`) after each transfer to avoid "too many interactions" errors.

### Capability Flags

HAL defines capability flags as a bitmask so the broker can check what a machine supports:

```lua
HAL.CAP_ITEM_INPUT   = 1    -- has input bus
HAL.CAP_ITEM_OUTPUT  = 2    -- has output bus
HAL.CAP_FLUID_INPUT  = 4    -- has input hatch
HAL.CAP_FLUID_OUTPUT = 8    -- has output hatch
HAL.CAP_POWER_EU     = 16   -- runs on EU
```

Usage:
```lua
if hal:hasCapability(machineType, HAL.CAP_FLUID_INPUT) then
  -- configure fluid export
end
```

---

## Module 3: BufferSnapshot.lua — Stability Debouncing

**File:** `src/BufferSnapshot.lua`  
**Role:** Prevents acting on buffer contents that are still changing.

### The Problem It Solves

Items arrive in the central buffer over multiple game ticks. If we snapshot the buffer while items are still flowing in, we'd create a job for a partial set — then create ANOTHER job when the rest arrive. The snapshot waits for the buffer to hold the same checksum for `debounceWindow` seconds before declaring it "stable."

### Public API

```lua
local snap = BufferSnapshot.new(1.5)  -- 1.5 second stability window

-- Feed poll data every tick
local isStable = snap:update({ items = {...}, fluids = {...} })

if isStable then
  -- Buffer hasn't changed for 1.5 seconds — safe to act
  local data = snap:getSnapshotData()  -- { items = {...}, fluids = {...} }
  local manifest = snap:convertToManifest(jobId)
  snap:reset()  -- start fresh cycle
end
```

### How Stability Detection Works

1. Each `update()` call computes a checksum of the buffer contents (FNV-1a hash)
2. If checksum matches the previous call, increment a stability counter
3. If checksum differs, reset the counter and record the new timestamp
4. When the same checksum has been stable for `debounceWindow` seconds → return true

### Data Flow Through the Snapshot

```
bufferFeeder returns:
  { items = [{name, label, size, damage, nbt}, ...], fluids = [{name, label, amount}, ...] }

↓ snapshot:update(bufferData)

getSnapshotData() returns:
  { items = [{name, label, size, damage, nbt}, ...], fluids = [{label, amount}, ...] }

↓ convertToManifest(jobId)

manifest.inputs = {
  items = [{name, label, size, damage, nbt}, ...],
  fluids = [{label, amount}, ...]
}
```

**Important:** `getSnapshotData()` preserves ALL fields from the bufferFeeder output, including `damage` and `nbt`. These are needed for accurate AE2 Database entries.

---

## Module 4: JobManifest.lua — The Work Order

**File:** `JobManifest.lua`  
**Role:** Represents a single unit of work. Tracks state from creation through completion.

### Lifecycle

```
BUFFERING → LOGGING → ALLOCATING → TRANSFERRING → PROCESSING → CLEANUP → COMPLETED
                                                    Any state → FAULTED
```

### Public API

| Method | Purpose |
|--------|---------|
| `JobManifest.new(id, inputs)` | Create a job with an ID and input specification |
| `updateState(newState)` | Transition to a new state (validates the transition) |
| `fault(reason)` | Transition to FAULTED with a reason string |
| `bindHardware(address)` | Record which machine is handling this job |
| `unbindHardware()` | Release the hardware binding |
| `isTerminal()` | True if COMPLETED or FAULTED |
| `isStale()` | True if job has exceeded its state-specific timeout |
| `age()` | Seconds since job creation |

### Input Specification

```lua
manifest.inputs = {
  items = {
    { name = "gregtech:gt.integrated_circuit", label = "Programmed Circuit", size = 1, damage = 9, nbt = nil },
    { name = "minecraft:iron_ingot", label = "Iron Ingot", size = 64, damage = 0, nbt = nil },
  },
  fluids = {
    { name = "water", label = "Water", amount = 1000 },
  },
}
```

### State Timeouts

Each state has a maximum allowed duration. If exceeded, the job is considered stale and should be faulted:

| State | Timeout | Rationale |
|-------|---------|-----------|
| BUFFERING | 120s | Buffer should stabilize quickly |
| ALLOCATING | 300s | Machine might be stuck |
| TRANSFERRING | 600s | AE2 might be slow; generous timeout |
| PROCESSING | 3600s | GT recipes can take a long time |

---

## Module 5: MachineNode.lua — Machine State

**File:** `src/MachineNode.lua`  
**Role:** Tracks the state of one GT machine. Manages lock/release lifecycle.

### Machine States

```
AVAILABLE → LOCKED → PROCESSING → (back to AVAILABLE after release)
                   ↘ FAULTED    → (back to AVAILABLE after clearFault)
```

### Public API

| Method | Purpose |
|--------|---------|
| `MachineNode.new(address, opts)` | Create a machine node |
| `isAvailable()` | True if machine can accept a job |
| `lock()` | Reserve this machine for a job |
| `unlock()` | Release the lock (used if bind fails) |
| `bindJob(manifest)` | Attach a job to this machine |
| `releaseJob()` | Detach the job, return to AVAILABLE |
| `pollHardware()` | Check the machine's current status via OC proxy |
| `hasFault()` | True if the machine has active fault flags |
| `injectFault(code, desc)` | (Testing) Inject a fault for fault-injection tests |
| `clearFault()` | Clear fault flags (after repair) |
| `flushInterface()` | Clear all 9 ME Interface config slots (ghost item cleanup) |
| `toTelemetry()` | Export machine state for telemetry broadcast |

### Interface Address

Each machine node can have an `interfaceAddress` — the UUID of the Dual Interface that serves this machine. This is used by `flushInterface()` to clear ghost items after a job completes.

---

## Module 6: JobQueue.lua — Scheduling

**File:** `JobQueue.lua`  
**Role:** Priority queue for pending jobs. Simple FIFO with optional priority.

### Public API

| Method | Purpose |
|--------|---------|
| `JobQueue.new(maxSize)` | Create a queue with capacity limit |
| `push(job)` | Add a job to the queue (returns false if full) |
| `popNextAvailable()` | Remove and return the next job |
| `length()` | Number of jobs waiting |
| `peek()` | Look at next job without removing it |

---

## Module 7: MaintenanceReport.lua — Fault Tracking

**File:** `MaintenanceReport.lua`  
**Role:** Per-machine fault log. Records what went wrong and when.

### Public API

| Method | Purpose |
|--------|---------|
| `MaintenanceReport.new(machineId)` | Create a report for a machine |
| `reportFault(code, description)` | Log a fault with severity code |
| `clearFault(message)` | Clear the fault (after successful completion) |
| `toHumanReadable(code)` | Convert fault code to text |

---

## Module 8: broker_logger.lua — Diagnostics

**File:** `src/broker_logger.lua`  
**Role:** Structured logging for debugging. Used extensively by exec_broker.

### Usage

```lua
local logger = BrokerLogger.new("LCR-arr")
logger:info("Phase: BUFFERING -> ALLOCATING (cycle 3)")
logger:debug("BUFFERING: slot[7] name=gregtech:gt.integrated_circuit count=1 dmg=9")
logger:warn("BUFFERING: bufferFeeder returned non-table: nil")
logger:error("TRANSFER: Cannot resolve transfer sides")
```

### Log Levels

| Level | When to Use |
|-------|-------------|
| `debug` | Slot-by-slot buffer scanning, detailed state dumps |
| `info` | Phase transitions, job creation/completion |
| `warn` | Recoverable issues (feeder returns nil, queue full) |
| `error` | Hard failures (config missing, proxy errors) |

---

## The Transfer Model in Detail

This is the most complex part of the system. Here's exactly what happens when a job reaches the TRANSFERRING phase:

### Step-by-step (per job, per tick)

```
TICK 1: store
  ┌─────────────────────────────────────────┐
  │ For each item in manifest.inputs.items: │
  │   Database[slot] ← {name, damage, nbt}  │
  │   (max 9 slots, JIT allocation)         │
  │ For each fluid in manifest.inputs.fluids│
  │   Database[slot] ← {name, 0, nil}       │
  │   → advance to "stock"                  │
  └─────────────────────────────────────────┘

TICK 2: stock + yield
  ┌─────────────────────────────────────────┐
  │ For each item DB slot:                  │
  │   iface.setInterfaceConfiguration(      │
  │     slot, dbAddress, dbSlot, 64)        │
  │ For each fluid DB slot:                 │
  │   iface.setFluidInterfaceConfiguration( │
  │     side, dbAddress, dbSlot)            │
  │   → advance to "wait", yield to AE2     │
  └─────────────────────────────────────────┘

TICK 3-5: wait (polling loop)
  ┌─────────────────────────────────────────┐
  │ Wait ≥3 ticks for AE2 to pull items     │
  │ Check iface slot 1 via checkSlotCount() │
  │ If empty → keep waiting (max 20 ticks)  │
  │ If stocked → advance to "pull"          │
  │ Timeout → fault job                     │
  └─────────────────────────────────────────┘

TICK 6: pull
  ┌─────────────────────────────────────────┐
  │ transposer.transferItem(                │
  │   ifaceSide, inputSide, 64)             │
  │   → advance to "verify", yield          │
  └─────────────────────────────────────────┘

TICK 7: verify
  ┌─────────────────────────────────────────┐
  │ Check interface is empty                │
  │ If items remain → pull again, re-verify │
  │ If empty → advance to "clear"           │
  └─────────────────────────────────────────┘

TICK 8: clear
  ┌─────────────────────────────────────────┐
  │ Clear all interface config slots        │
  │ Clear fluid export config               │
  │ Clear all Database slots                │
  │ → manifest:updateState("PROCESSING")    │
  └─────────────────────────────────────────┘
```

### Why AE2 Does the Heavy Lifting

The old model used `drainInventory` to move items directly from the central buffer to the machine via transposer. This had problems:
- Transposer had to touch both the buffer AND the machine — physically impossible in many layouts
- No way to track partial transfers
- Items could get stuck in the transposer

The new model lets AE2's network handle the buffer-to-interface leg. AE2 is purpose-built for item routing — let it do its job. The transposer is only used for the short, predictable hops within a single lane.

---

## Development Guide

### Adding a New Feature

1. **Read the module docs above** to find which module owns the behavior you need to change
2. **Write a failing test first** in the appropriate test file
3. **Implement** using HAL for any OC component interaction
4. **Run `python run_tests.py`** — all 128 tests must pass (or explain why any don't)
5. **Commit** with a conventional commit message: `feat:`, `fix:`, `refactor:`, `test:`

### Testing

```bash
# Run all tests
python run_tests.py

# Run just integration tests
python -c "import subprocess; subprocess.run(['python', 'run_tests.py'])"

# Compile-check a single file
luac -p src/exec_broker.lua
```

**Test files:**

| File | What it tests |
|------|---------------|
| `test_integration.lua` | Full broker lifecycle with mock OC environment |
| `test_state_transitions.lua` | JobManifest state machine validation |
| `ocemu_test_suite.lua` | Module loading + OC API interaction (CI-safe) |
| `tests/helpers/mock_modules.lua` | Recording stubs for HAL, MachineNode, etc. |

### Common Pitfalls

1. **Direct OC component access:** Never call `component.proxy()` or `transposer.transferItem()` outside of hal.lua. Always go through HAL.
2. **Missing `.size` on stacks:** In GTNH, `getStackInSlot` may not include `.size`. Use `checkSlotCount()` which has the fallback to `getSlotStackSize`.
3. **Config key mismatch:** `machineTransposers` is keyed by `laneId` (e.g. "Lane 1"), but the broker internally uses machine UUIDs. Always resolve through `_machineList`.
4. **Database slot collision:** Only 9 Database slots exist. The TRANSFERRING phase uses them JIT and clears them before PROCESSING. Never store Database entries that outlive a single transfer cycle.
5. **Multi-tick transfer:** The transfer pipeline spans 5-8 ticks. Tests need enough tick iterations. If a test broker goes ALLOCATING → CLEANUP instantly, check that `machineTransposers` config exists for the lane.

### Debugging Live Brokers

The broker logger outputs at 4 levels. Watch for these patterns:

```
[INFO]  Phase: BUFFERING -> ALLOCATING     ← normal phase transition
[DEBUG] TRANSFER: DB[1] ← item_name        ← Database storage
[INFO]  TRANSFER: lane X iface[1] ← DB[1]  ← interface configured
[INFO]  Phase: TRANSFERRING -> PROCESSING   ← transfer complete

[WARN]  No transposer config for lane X    ← missing machineTransposers config
[DEBUG] TRANSFER: interface slot 1 still empty ← AE2 hasn't delivered yet (normal, retries)
[ERROR] Cannot resolve transfer sides      ← halSideMap missing a role
```
