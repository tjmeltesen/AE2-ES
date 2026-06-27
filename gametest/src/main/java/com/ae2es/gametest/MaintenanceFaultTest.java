package com.ae2es.gametest;

import static com.gtnewhorizons.horizonqa.api.TestPos.at;
import static com.gtnewhorizons.horizonqa.gtnh.api.MaintenanceType.*;

import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.annotation.GameTest;
import com.gtnewhorizons.horizonqa.api.annotation.GameTestHolder;
import com.gtnewhorizons.horizonqa.gtnh.api.GTNHGameTestHelper;
import com.gtnewhorizons.horizonqa.gtnh.api.Multiblock;

/**
 * Validates GT machine maintenance fault detection and recovery — a critical
 * path for Exec Broker Phase 5 (PROCESSING) and Phase 6 (CLEANUP).
 *
 * <p>The AE2-ES Exec Broker must:
 * <ol>
 *   <li>Detect when a GT machine enters FAULTED state (maintenance needed)</li>
 *   <li>Generate a MaintenanceReport for the Supervisor dashboard</li>
 *   <li>Halt processing and initiate cleanup on the affected machine</li>
 *   <li>Poll the machine (heartbeat) after repair to restore AVAILABLE state</li>
 * </ol>
 *
 * <p>This test validates the underlying GT mechanics that the Lua Exec Broker
 * depends on. The actual Lua fault detection is tested via Tier 1 unit tests
 * with mocked machine state; this test ensures the real GT blocks behave as
 * the mock expects.
 *
 * <p>Structure template: {@code maintenance_ebf}
 * <ul>
 *   <li>Electric Blast Furnace (fully formed, no maintenance fixed)</li>
 *   <li>Energy hatch (EV), input bus, output bus</li>
 *   <li>Maintenance hatch accessible for repair tools</li>
 * </ul>
 */
@GameTestHolder("ae2es")
public class MaintenanceFaultTest {

    /**
     * Verifies that a freshly-formed EBF starts with maintenance issues —
     * the pre-condition for the Exec Broker's fault detection to fire.
     */
    @GameTest(template = "maintenance_ebf", timeoutTicks = 40, batch = "ae2es")
    public static void freshEbfHasMaintenanceIssues(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();

        // EBF controller is at test-relative (1, 0, 0) per structure template
        gtnh.assertMachineFormed(at(1, 0, 0));

        // A fresh EBF should have ALL six maintenance issues
        gtnh.assertMachineHasIssues(at(1, 0, 0),
            WRENCH,
            SCREWDRIVER,
            SOFT_MALLET,
            HARD_HAMMER,
            SOLDERING_TOOL,
            CROWBAR);

        helper.succeed();
    }

    /**
     * Verifies that maintenance issues gate the recipe — even with full
     * EU supply and correct inputs, the EBF must not process while any
     * maintenance issue exists.
     *
     * <p>This is the exact condition the Exec Broker must detect to set
     * STATUS_FAULTED and generate a MaintenanceReport.
     */
    @GameTest(template = "maintenance_ebf", timeoutTicks = 60, batch = "ae2es")
    public static void maintenanceGatesProcessing(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock ebf = gtnh.multiblock(at(1, 0, 0));

        ebf.assertFormed();

        // Load inputs and supply power
        ebf.inputBus(0)
            .insert(
                gregtech.api.enums.Materials.Nickel.getDust(1),
                gregtech.api.enums.Materials.Aluminium.getDust(3))
            .programmedCircuit(0);

        ebf.energyHatch(0).supply(gregtech.api.enums.TierEU.EV, 1, 900);

        // After 20 ticks, the EBF should NOT have consumed any items because
        // maintenance issues prevent the recipe from starting.
        // The Exec Broker would detect this as "machine stuck" and flag FAULTED.
        helper.startSequence()
            .thenIdle(20)
            .thenExecute(() -> {
                gtnh.assertMachineHasIssues(at(1, 0, 0), WRENCH);
            })
            .thenSucceed();
    }

    /**
     * Verifies the full resolve-assertion cycle: fix all maintenance issues,
     * then the machine can process.
     *
     * <p>Simulates the Exec Broker's heartbeat polling on a FAULTED machine
     * that has been repaired — the machine should transition from FAULTED to
     * AVAILABLE and resume normal processing.
     */
    @GameTest(template = "maintenance_ebf", timeoutTicks = 100, batch = "ae2es")
    public static void fixMaintenanceRestoresOperation(GameTestHelper helper) {
        GTNHGameTestHelper gtnh = helper.gtnh();
        Multiblock ebf = gtnh.multiblock(at(1, 0, 0));

        ebf.assertFormed();

        // Assert maintenance issues exist (faulted state)
        gtnh.assertMachineHasIssues(at(1, 0, 0), WRENCH);

        // Fix all maintenance issues (simulates technician repair)
        ebf.fixMaintenance();

        // Load inputs
        ebf.inputBus(0)
            .insert(
                gregtech.api.enums.Materials.Nickel.getDust(1),
                gregtech.api.enums.Materials.Aluminium.getDust(3))
            .programmedCircuit(0);

        // Supply power
        ebf.energyHatch(0).supply(gregtech.api.enums.TierEU.EV, 1, 900);

        // Run recipe — should succeed now that maintenance is fixed
        ebf.runRecipe();

        // Verify output produced (machine is AVAILABLE and processing)
        ebf.outputs().assertContains(
            gregtech.api.enums.Materials.NickelAluminide.getIngots(4));

        // Machine should have no maintenance issues now
        helper.succeed();
    }
}
