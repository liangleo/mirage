package app.mirage.net

import org.junit.Assert.assertEquals
import org.junit.Test

class E2eTest {
    @Test
    fun computesMilliseconds() {
        assertEquals(20, E2e.compute(1_020_100, 100, 1_000_000))
    }

    @Test
    fun rejectsNegativeAndZeroCaptureTimestamps() {
        assertEquals(-1, E2e.compute(1_000_000, 0, 0))
        assertEquals(-1, E2e.compute(1_000_000, 0, -5))
    }

    @Test
    fun rejectsResultsAboveTenSeconds() {
        assertEquals(-1, E2e.compute(20_000_000, 0, 1_000_000))
    }

    @Test
    fun rejectsNegativeResults() {
        assertEquals(-1, E2e.compute(1_000_000, 10_000_000, 900_000))
    }
}