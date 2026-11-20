package app.mirage.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReconnectPolicyTest {
    @Test
    fun backoffDoublesUpToFiveSeconds() {
        assertEquals(500, ReconnectPolicy.innerBackoffMs(1))
        assertEquals(1_000, ReconnectPolicy.innerBackoffMs(2))
        assertEquals(2_000, ReconnectPolicy.innerBackoffMs(3))
        assertEquals(4_000, ReconnectPolicy.innerBackoffMs(4))
        assertEquals(5_000, ReconnectPolicy.innerBackoffMs(5))
        assertEquals(5_000, ReconnectPolicy.innerBackoffMs(10))
    }

    @Test
    fun innerExhaustsAfterTenAttempts() {
        assertFalse(ReconnectPolicy.innerExhausted(10))
        assertTrue(ReconnectPolicy.innerExhausted(11))
    }

    @Test
    fun outerWindowIsFiveMinutes() {
        assertEquals(5_000, ReconnectPolicy.OUTER_RETRY_MS)
        assertEquals(300_000, ReconnectPolicy.OUTER_WINDOW_MS)
    }
}