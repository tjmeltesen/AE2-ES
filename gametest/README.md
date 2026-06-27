# AE2-ES GameTest Suite

Horizon-QA based integration tests for the AE2 Execution System, validating against real AE2, GregTech, and OpenComputers mod blocks in a Forge 1.7.10 server.

## Test Classes

| Class | Template | Tests | What It Validates |
|-------|----------|-------|-------------------|
| `ModemBroadcastTest` | `modem_network` | 3 | 4-broker modem topology, redstone gating, broadcast range |
| `TransposerTransferTest` | `transposer_chain` | 3 | Item transfer: AE2 Interface → Transposer → GT Input Bus |
| `MaintenanceFaultTest` | `maintenance_ebf` | 3 | GT machine maintenance detection, gating, and recovery |
| `DebounceWindowTest` | `debounce_cell` | 3 | BufferSnapshot stability window and redstone lock timing |
| `GhostItemTest` | `ghost_item_cell` | 4 | Ghost-item detection (10s timeout) and blind-flush cleanup |

**Total: 16 tests** across 5 test classes in the `ae2es` batch.

## Structure Templates

Each test class depends on a structure template (`.json` + `.snbt`) in:

```
src/main/resources/assets/ae2es/horizonqastructures/
```

Templates are built in a creative GTNH world using the **Horizon Wand** (`/horizonqa export <name>`). See [Structure Building Guide](STRUCTURES.md) for detailed instructions.

### Template Summary

| Template File | Dimensions | Contents |
|---------------|------------|----------|
| `modem_network` | 8×4×6 | 4 OC Cases + Modems, 1 Supervisor Case + Modem, Redstone Gatekeeper I/O blocks, Lock lever |
| `transposer_chain` | 3×3×3 | AE2 Dual Interface, OC Transposer, GT Machine (Input Bus), Redstone trigger line |
| `maintenance_ebf` | 5×5×5 | Electric Blast Furnace (fully formed, no maintenance), Energy Hatch (EV), Input Bus, Output Bus, Maintenance Hatch |
| `debounce_cell` | 3×4×3 | Central buffer (chest/AE2 Interface 27-slot), Redstone I/O block, Redstone NOT gate, Lock lever |
| `ghost_item_cell` | 3×3×3 | GT Machine with Input Bus, Return Line (hopper/chest), Redstone flush trigger line |

## Building

This is a Gradle project using the GTNH convention plugin:

```bash
cd gametest
./gradlew build
```

### Dependencies

All dependencies are `compileOnly` — the Forge server provides them at runtime:

- `com.github.GTNewHorizons:Horizon-QA:0.6.0` — GameTest framework
- `com.github.GTNewHorizons:GT5-Unofficial:5.09.52.482` — GregTech
- `com.github.GTNewHorizons:Applied-Energistics-2-Unofficial:rv3-beta-922-GTNH` — AE2
- `com.github.GTNewHorizons:OpenComputers:1.10.36-GTNH` — OpenComputers

## Running Tests

### In CI (Headless)

```bash
./gradlew runServer --mcJvmArgs="-Dhorizonqa.mode=ci \
  -Dhorizonqa.reportDir=build/horizonqa \
  -Dhorizonqa.batch=ae2es"
```

Outputs:
- `build/horizonqa/TEST-horizonqa.xml` — JUnit XML report
- `build/horizonqa/horizonqa-result.json` — Status JSON

### In Development (Interactive)

```bash
./gradlew runServer
# In-game commands:
# /horizonqa runall ae2es
# /horizonqa runfailed
# /horizonqa export <name>
# /horizonqa pos
```

## Relationship to AE2-ES

These GameTests validate the **Minecraft-level mechanics** that the AE2-ES Lua system depends on:

- **Tier 1** (Lua unit tests) — validates Lua logic with mocked components
- **Tier 2** (These tests) — validates that real mod blocks behave as the mocks expect
- **Tier 3** (Soak tests) — validates stability over extended operation

The Lua Exec Broker and Supervisor are NOT tested directly here (they run Lua code on OC computers, which Horizon-QA cannot execute). Instead, these tests ensure the physical infrastructure — redstone gating, item transfer, machine states, inventory behavior — matches what the Lua code expects.

## CI Integration

See `.github/workflows/ae2-es-ci.yml` — the `tier2-horizon-qa-gametest` job runs these tests on PR to main.
