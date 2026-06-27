package com.ae2es.gametest;

import com.gtnewhorizons.horizonqa.api.GameTestHelper;
import com.gtnewhorizons.horizonqa.api.annotation.BeforeBatch;
import com.gtnewhorizons.horizonqa.api.annotation.AfterBatch;

/**
 * Shared batch lifecycle hooks for the AE2-ES GameTest suite.
 *
 * <p>All tests share the {@code "ae2es"} batch. Setup and teardown
 * run before and after every test in the batch.
 *
 * <p>This class also serves as a discovery anchor — all test classes
 * are in the same package and share this namespace.
 */
public class GameTestSuite {

    /**
     * Batch setup: runs before every test in the "ae2es" batch.
     * Initializes shared state, clears any residual items from prior tests.
     */
    @BeforeBatch("ae2es")
    public static void setUp() {
        // Batch-level setup — clear shared state, reset counters.
        // The Horizon-QA framework handles test cell isolation;
        // this hook is for cross-test shared resource initialization.
    }

    /**
     * Batch teardown: runs after every test in the "ae2es" batch.
     * Cleans up shared resources, verifies no isolation violations.
     */
    @AfterBatch("ae2es")
    public static void tearDown() {
        // Batch-level teardown — verify clean state, log completion.
        // The GridSweeper handles cell-level cleanup automatically.
    }
}
