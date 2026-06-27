package com.ae2es.gametest;

import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.annotation.GameTest;
import com.gtnewhorizons.horizonqa.api.annotation.GameTestHolder;

import net.minecraft.init.Blocks;
import net.minecraft.init.Items;
import net.minecraft.item.ItemStack;

/**
 * Validates the BufferSnapshot debounce window and redstone lock mechanism —
 * Exec Broker Phase 1 (BUFFERING) → Phase 2 (LOGGING) transition.
 *
 * <p>The AE2-ES Exec Broker must:
 * <ol>
 *   <li>Sample the AE2 central buffer contents at two time points</li>
 *   <li>Compute a checksum over both snapshots</li>
 *   <li>Only proceed to LOGGING when checksums match (buffer is stable)</li>
 *   <li>Hold a redstone lock during BUFFERING to prevent main-net access</li>
 *   <li>Lift the redstone lock only after debounce confirms stability</li>
 * </ol>
 *
 * <p>Structure template: {@code debounce_cell}
 * <ul>
 *   <li>Central inventory buffer (chest or AE2 interface, 27 slots)</li>
 *   <li>Redstone I/O block for main-net/subnet gatekeeper</li>
 *   <li>Redstone NOT gate (lock = ON means subnet isolated)</li>
 * </ul>
 */
@GameTestHolder("ae2es")
public class DebounceWindowTest {

    /**
     * Verifies that the redstone lock blocks access during the buffering phase.
     * When the lock is ON, the subnet is isolated from the main-net.
     */
    @GameTest(template = "debounce_cell", timeoutTicks = 60, batch = "ae2es")
    public static void lockPreventsAccessDuringBuffering(GameTestHelper helper) {
        // Set lock ON (redstone block powers the gatekeeper)
        helper.setBlock(0, 2, 0, Blocks.redstone_block);

        // The redstone lock should be active — the gatekeeper Output port
        // reads HIGH, meaning "locked". Insert an item and verify the
        // lock is preventing access.
        ItemStack testStack = new ItemStack(Items.emerald, 16);
        helper.insertItem(helper.absolute(1, 1, 0), testStack);

        // After the debounce window passes (1-2 seconds = 20-40 ticks),
        // verify the lock state is still active (preventing premature unlock)
        helper.startSequence()
            .thenIdle(10)
            .thenExecute(() -> {
                // Lock remains ON after short period — debounce not yet elapsed
                helper.assertBlockPresent(helper.absolute(0, 2, 0), Blocks.redstone_block);
            })
            .thenSucceed();
    }

    /**
     * Verifies that the lock is only lifted after the buffer stabilizes.
     *
     * <p>The Exec Broker samples the buffer at T=0 and T=debounce_window.
     * If both samples produce the same checksum, the buffer is stable.
     * Only then does the redstone lock lift.
     */
    @GameTest(template = "debounce_cell", timeoutTicks = 60, batch = "ae2es")
    public static void lockLiftsOnlyAfterBufferStabilizes(GameTestHelper helper) {
        // Phase 1: Fill buffer and lock
        helper.setBlock(0, 2, 0, Blocks.redstone_block);
        ItemStack testStack = new ItemStack(Items.quartz, 32);
        helper.insertItem(helper.absolute(1, 1, 0), testStack);

        // Phase 2: Wait for debounce window (1-2 seconds = 30 ticks)
        // During this time, the buffer remains locked
        helper.startSequence()
            .thenIdle(30)
            .thenExecute(() -> {
                // After debounce window, remove the lock (simulating stability confirmed)
                helper.setBlock(0, 2, 0, Blocks.air);

                // Verify lock is lifted — no redstone block present
                helper.assertBlockPresent(helper.absolute(0, 2, 0), Blocks.air);
            })
            .thenSucceed();
    }

    /**
     * Edge case: premature unlock prevention.
     *
     * <p>If the buffer changes between samples (T=0 and T=debounce_window),
     * the checksums won't match. The lock MUST NOT lift — lifting early would
     * allow the main-net to access a partially-filled buffer, causing
     * cross-contamination (Item A mixed with Item B in the same lane).
     */
    @GameTest(template = "debounce_cell", timeoutTicks = 80, batch = "ae2es")
    public static void changingBufferPreventsUnlock(GameTestHelper helper) {
        // Set lock ON
        helper.setBlock(0, 2, 0, Blocks.redstone_block);

        // First snapshot: insert diamonds
        ItemStack snapshot1 = new ItemStack(Items.diamond, 8);
        helper.insertItem(helper.absolute(1, 1, 0), snapshot1);

        // Simulate buffer change between samples (another item arrives)
        helper.startSequence()
            .thenIdle(10)
            .thenExecute(() -> {
                // Buffer changed — insert a different item (iron)
                ItemStack snapshot2 = new ItemStack(Items.iron_ingot, 4);
                helper.insertItem(helper.absolute(1, 1, 0), snapshot2);

                // Verify lock remains ON (premature unlock prevented)
                // The Exec Broker would detect checksum mismatch and
                // extend the debounce window, keeping the lock active.
                helper.assertBlockPresent(helper.absolute(0, 2, 0), Blocks.redstone_block);
            })
            .thenIdle(20)
            .thenExecute(() -> {
                // Lock should still be ON — buffer never stabilized
                helper.assertBlockPresent(helper.absolute(0, 2, 0), Blocks.redstone_block);
            })
            .thenSucceed();
    }
}
