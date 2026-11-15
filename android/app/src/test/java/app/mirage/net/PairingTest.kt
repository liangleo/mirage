package app.mirage.net

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PairingTest {
    private val fingerprint = ByteArray(32) { it.toByte() }
    private val deviceID = "11111111-2222-3333-4444-555555555555"

    @Test
    fun roundTrips() {
        val payload = PairingPayload("192.168.1.20", 7777, fingerprint, "Leo 的 Mac", deviceID)
        val url = requireNotNull(payload.encodeURL())
        val decoded = requireNotNull(PairingPayload.parse(url))
        assertEquals(payload.host, decoded.host)
        assertEquals(payload.port, decoded.port)
        assertArrayEquals(payload.fingerprint, decoded.fingerprint)
        assertEquals(payload.name, decoded.name)
        assertEquals(payload.deviceID, decoded.deviceID)
    }

    @Test
    fun ipv6HostRoundTrips() {
        val payload = PairingPayload("fe80::1", 7778, fingerprint, "Mac", deviceID)
        assertEquals("fe80::1", PairingPayload.parse(requireNotNull(payload.encodeURL()))?.host)
    }

    @Test
    fun rejectsInvalidUrls() {
        val hex = fingerprint.joinToString("") { "%02x".format(it) }
        val base = "mirage://pair?v=1&host=1.2.3.4&port=7777&fp=$hex&name=Mac&id=$deviceID"

        assertNotNull(PairingPayload.parse(base))
        assertNull(PairingPayload.parse(base.replace("v=1", "v=2")))
        assertNull(PairingPayload.parse(base.replace(hex, "abcd")))
        assertNull(PairingPayload.parse(base.replace("port=7777", "port=0")))
        assertNull(PairingPayload.parse(base.replace("port=7777", "port=65536")))
        assertNull(PairingPayload.parse(base.replace(deviceID, "nope")))
        assertNull(PairingPayload.parse("https://pair?v=1&host=1.2.3.4&port=7777&fp=$hex&id=$deviceID"))
    }

    @Test
    fun decodesFingerprint() {
        val hex = fingerprint.joinToString("") { "%02x".format(it) }
        assertArrayEquals(fingerprint, PairingPayload.decodeFingerprint(hex))
        assertNull(PairingPayload.decodeFingerprint("abc"))
        assertNull(PairingPayload.decodeFingerprint("g".repeat(64)))
    }
}