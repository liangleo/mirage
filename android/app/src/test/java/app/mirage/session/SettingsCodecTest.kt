package app.mirage.session

import app.mirage.net.TransportMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SettingsCodecTest {
    @Test
    fun decodesMissingKeysWithDefaults() {
        val settings = SettingsCodec.decode(emptyMap<String, Any?>())
        assertEquals("", settings.host)
        assertEquals(0, settings.port)
        assertEquals(TransportMode.AUTO, settings.transportMode)
        assertFalse(settings.debugOn)
        assertTrue(settings.inputOn)
    }

    @Test
    fun roundTripsDebugAndInputFlags() {
        val original = PersistedSettings(
            host = "192.168.1.10",
            port = 7778,
            fingerprint = "ab".repeat(32),
            deviceIdHex = "00".repeat(16),
            transportMode = TransportMode.WIFI,
            debugOn = true,
            inputOn = false
        )
        assertEquals(original, SettingsCodec.decode(SettingsCodec.encode(original)))
    }

    @Test
    fun invalidTransportModeFallsBackToAuto() {
        val settings = SettingsCodec.decode(mapOf("transportMode" to "NOPE"))
        assertEquals(TransportMode.AUTO, settings.transportMode)
    }

    @Test
    fun pairedAddressIsOnlyWrittenOnWifiSuccess() {
        assertTrue(SettingsCodec.shouldPersistPairing(isWifi = true, success = true))
        assertFalse(SettingsCodec.shouldPersistPairing(isWifi = false, success = true))
        assertFalse(SettingsCodec.shouldPersistPairing(isWifi = true, success = false))
    }
}