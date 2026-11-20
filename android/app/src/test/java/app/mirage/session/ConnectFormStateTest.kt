package app.mirage.session

import app.mirage.net.TransportMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectFormStateTest {
    private val fingerprint = "ab".repeat(32)

    @Test
    fun emptyHostIsInvalid() {
        val result = ConnectForm.validate("", "7778", fingerprint, TransportMode.WIFI)
        assertTrue(result is ConnectValidation.Invalid)
    }

    @Test
    fun portOutOfRangeIsInvalid() {
        val result = ConnectForm.validate("192.168.1.10", "70000", fingerprint, TransportMode.WIFI)
        assertTrue(result is ConnectValidation.Invalid)
    }

    @Test
    fun wifiRequiresFingerprint() {
        val result = ConnectForm.validate("192.168.1.10", "7778", "", TransportMode.WIFI)
        assertTrue(result is ConnectValidation.Invalid)
    }

    @Test
    fun loopbackWifiDoesNotRequireFingerprint() {
        val result = ConnectForm.validate("127.0.0.1", "7778", "", TransportMode.WIFI)
        assertTrue(result is ConnectValidation.Valid)
    }

    @Test
    fun tcpIgnoresHostAndUses7777() {
        val result = ConnectForm.validate("", "", "", TransportMode.TCP)
        assertEquals(ConnectFields("127.0.0.1", 7777, ""), (result as ConnectValidation.Valid).fields)
    }

    @Test
    fun autoAllowsEmptyHost() {
        val result = ConnectForm.validate("", "", "", TransportMode.AUTO)
        assertTrue(result is ConnectValidation.Valid)
    }

    @Test
    fun switchingToWifiDefaultsPortTo7778() {
        assertEquals(7778, ConnectForm.defaultPort(TransportMode.WIFI))
        assertEquals(7778, ConnectForm.defaultPort(TransportMode.AUTO))
    }

    @Test
    fun switchingToTcpDefaultsPortTo7777() {
        assertEquals(7777, ConnectForm.defaultPort(TransportMode.TCP))
    }

    @Test
    fun nonLoopbackWifiWithoutFingerprintIsRejected() {
        val result = ConnectForm.validate("10.0.0.2", "7778", "not-a-fingerprint", TransportMode.WIFI)
        assertTrue(result is ConnectValidation.Invalid)
    }

    @Test
    fun pairingLinkFillsHostPortFingerprint() {
        val link = "mirage://pair?v=1&host=192.168.1.10&port=7778&fp=$fingerprint&name=Mac&id=00000000-0000-0000-0000-000000000001"
        val fields = ConnectForm.fromPairing(link)
        assertNotNull(fields)
        assertEquals("192.168.1.10", fields!!.host)
        assertEquals(7778, fields.port)
        assertEquals(fingerprint, fields.fingerprintHex)
    }
}