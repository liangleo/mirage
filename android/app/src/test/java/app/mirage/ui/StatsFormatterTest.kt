package app.mirage.ui

import app.mirage.net.StatsSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StatsFormatterTest {
    private fun snapshot(
        e2e: Long = 11,
        p95: Long = -1,
        rtt: Long = 20,
        decode: Long = 11,
        codec: String = "HW"
    ) = StatsSnapshot(
        fps = 59,
        decodeMs = decode,
        bitrateMbps = 6.7,
        dropped = 0,
        e2eMs = e2e,
        rttMs = rtt,
        codec = codec,
        e2eP95Ms = p95
    )

    @Test
    fun formatsP95WhenPresent() {
        val lines = StatsFormatter.format(snapshot(p95 = 248), "Wi-Fi UDP", 2880, 1920)
        assertEquals("59 fps · 6.7 Mbps · drop 0", lines.first)
        assertEquals("p95 248ms", lines.p95)
    }

    @Test
    fun showsP95PlaceholderWhenAbsent() {
        val lines = StatsFormatter.format(snapshot(), "Wi-Fi", 2880, 1920)
        assertEquals("59 fps · 6.7 Mbps · drop 0", lines.first)
        assertEquals("p95 --", lines.p95)
    }

    @Test
    fun showsDashesWithoutE2eOrRtt() {
        val lines = StatsFormatter.format(snapshot(e2e = -1, rtt = -1), "Wi-Fi", 0, 0)
        assertEquals("decode 11.0ms · e2e -- · RTT -- · HW", lines.second)
    }

    @Test
    fun transportIncludesResolution() {
        val lines = StatsFormatter.format(snapshot(), "Wi-Fi UDP", 2880, 1920)
        assertEquals("Wi-Fi UDP 2880×1920", lines.transport)
    }

    @Test
    fun volumeAndBackAreNotConsumed() {
        assertFalse(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_BACK))
        assertFalse(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_VOLUME_UP))
        assertFalse(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_VOLUME_DOWN))
        assertFalse(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_VOLUME_MUTE))
    }

    @Test
    fun navigationKeysAreConsumedWhenKeyboardEnabled() {
        assertTrue(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_DPAD_UP))
        assertTrue(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_MOVE_HOME))
        assertTrue(KeyFilter.shouldHandle(android.view.KeyEvent.KEYCODE_A))
    }
}