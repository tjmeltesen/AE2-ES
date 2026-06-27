# Structure Building Guide

How to build the 5 structure templates required by the AE2-ES GameTest Suite.

## Prerequisites

- GTNH modpack with Horizon-QA mod (v0.6.0+) installed
- Horizon Wand (obtained via `/horizonqa wand`)
- Creative mode (for building)
- A flat test world

## General Workflow

1. Place blocks in the desired layout, including tile entities with NBT data
2. Stand at the center of the structure and run `/horizonqa pos` to get coordinate references
3. Select bounds with Horizon Wand: **Left Click** for pos1, **Right Click** for pos2
4. Run `/horizonqa export <name>`
5. Copy the exported files from `<serverDir>/horizonqastructures/` into:
   ```
   gametest/src/main/resources/assets/ae2es/horizonqastructures/
   ```
6. Verify: `<name>.json` + `<name>.snbt` (or `<name>.nbt`) must both exist

## Template Specifications

### 1. `modem_network` (8×4×6)
**Purpose:** 4-broker modem broadcast topology with Supervisor

```
Layer plan (top-down, Z-axis runs north):
  Z=0: [Case1] [    ] [Case2] [    ] [Case3] [    ] [Case4]
  Z=1: [Modem] [    ] [Modem] [    ] [Modem] [    ] [Modem]
  Z=2: [ GIO1] [    ] [ GIO2] [    ] [ GIO3] [    ] [ GIO4]
  Z=3: [ Wire] [Wire] [ Wire] [Wire] [ Wire] [Wire] [Lever]
  Z=4: [     ] [    ] [     ] [Supv] [     ] [    ] [     ]
  Z=5: [     ] [    ] [     ] [Mdem] [     ] [    ] [     ]

Legend:
  Case<N> = OpenComputers Case (tier 1) with EEPROM+Lua BIOS
  Modem = OpenComputers Modem (network card) on top of case
  GIO<N> = OpenComputers Redstone I/O block (gatekeeper)
  Wire = Redstone wire (vanilla)
  Lever = Redstone lever (central lock)
  Supv = OpenComputers Case (Supervisor)
  Mdem = OpenComputers Modem (Supervisor)
```

**Key requirements:**
- All Cases must have an EEPROM with Lua BIOS installed
- Modems must be placed directly on top of or adjacent to Cases
- Redstone I/O blocks must face the modem side
- Redstone wires must connect all gatekeepers to the central lever
- Computers must be pre-configured with `autorun.lua` disabled (or empty)

### 2. `transposer_chain` (3×3×3)
**Purpose:** AE2 Interface → Transposer → GT Machine item path

```
  Z=0: [ D I ]   D I = AE2 Dual Interface
  Z=1: [Trans]   Trans = OpenComputers Transposer
  Z=2: [GT In]   GT In = GT Machine (any single-block) with Input Bus side facing Transposer

  Redstone trigger line: Redstone dust at Y=2 flat on top of Transposer
```

**Key requirements:**
- AE2 Dual Interface fully configured (part of a working subnet, or standalone with items in config)
- Transposer facing the GT machine's input bus side
- GT machine must have an Input Bus configured
- Redstone dust must be placeable to trigger the transposer

### 3. `maintenance_ebf` (5×5×5)
**Purpose:** Electric Blast Furnace — fully formed, all 6 maintenance issues present

```
Standard EBF structure (3x4x3 hollow):
  - Controller at test-relative (1, 0, 0)
  - Energy Hatch (EV) at test-relative (0, 0, 0), south-facing
  - Input Bus at test-relative (1, 0, 1), east-facing
  - Output Bus at test-relative (1, 0, 2), east-facing
  - Maintenance Hatch at test-relative (2, 0, 0)
  - 34 Heatproof Machine Casings (standard EBF layout)
```

**Key requirements:**
- Must be a full 3×4×3 EBF with all casings (Muffler hatch as needed)
- Controller MUST be at (1, 0, 0)
- Do NOT fix any maintenance issues — the test relies on all 6 being present
- Energy hatch must be EV tier (at minimum)
- The structure must form when placed (it's a valid EBF)

### 4. `debounce_cell` (3×4×3)
**Purpose:** Central buffer with redstone lock mechanism

```
  Z=0: [     ] [ Chest ] [     ]
  Z=1: [     ] [  RIO  ] [     ]
  Z=2: [Torch] [  Dust ] [Torch]

  Chest = 27-slot inventory buffer (or AE2 Interface with terminal)
  RIO = OpenComputers Redstone I/O block
  Torch = Redstone torch (NOT gate)
  Dust = Redstone dust
```

**Key requirements:**
- Chest (or AE2 Interface) must be the central buffer
- Redstone I/O block must face the chest
- Redstone NOT gate (torch on side, dust on top) provides the lock signal
- Lock = ON means subnet isolated (torch extinguishes → RIO output set HIGH)

### 5. `ghost_item_cell` (3×3×3)
**Purpose:** GT Machine with input bus and return line

```
  Z=0: [GT In]   GT In = GT Machine Input Bus
  Z=1: [Hoppr]   Hoppr = Hopper (return line) facing away from GT machine
  Z=2: [      ]

  Flush trigger: Redstone block at X=-1, Y=0, Z=0 (off-structure, outside template)
```

**Key requirements:**
- GT machine (single-block, any type) with Input Bus facing up or toward the hopper
- Hopper must point into the GT machine's input bus (or out of it, depending on test design)
- Flush trigger via external redstone signal (test places redstone block at runtime)
- Input bus must be empty initially (ghost items are placed by the test)

## Verification

After exporting, verify each structure loads correctly:

```
/horizonqa run <test-id>
```

Example:
```
/horizonqa run ae2es:ModemBroadcastTest.allBrokersHaveModems
```

A `StructurePlaced` event in the log confirms the template loaded. `StructureNotFound` means the template files are missing or misnamed.
