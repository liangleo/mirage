package app.mirage.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TransportSelectorTest {
    @Test
    fun autoPrefersUsbThenWifiThenTcp() {
        assertEquals(
            TransportKind.USB,
            TransportSelector.select(TransportMode.AUTO, true, "192.168.1.5", 7778)?.kind
        )
        assertEquals(
            TransportKind.WIFI,
            TransportSelector.select(TransportMode.AUTO, false, "192.168.1.5", 7778)?.kind
        )
        assertEquals(
            TransportKind.TCP,
            TransportSelector.select(TransportMode.AUTO, false, "", 0)?.kind
        )
        assertEquals(
            TransportKind.TCP,
            TransportSelector.select(TransportMode.AUTO, false, "192.168.1.5", 0)?.kind
        )
    }

    @Test
    fun explicitUsbWaitsInsteadOfFallingBack() {
        val choice = TransportSelector.select(TransportMode.USB, false, "192.168.1.5", 7778)
        assertEquals(TransportKind.WAIT_USB, choice?.kind)
        assertEquals(null, choice?.host)
        assertEquals(TransportKind.USB, TransportSelector.select(TransportMode.USB, true, null, 0)?.kind)
    }

    @Test
    fun explicitWifiRequiresValidSavedAddress() {
        assertNull(TransportSelector.select(TransportMode.WIFI, false, "", 0))
        assertNull(TransportSelector.select(TransportMode.WIFI, false, "h", 70000))
        val choice = TransportSelector.select(TransportMode.WIFI, true, "10.0.2.2", 7778)
        assertEquals(TransportKind.WIFI, choice?.kind)
        assertEquals("10.0.2.2", choice?.host)
        assertEquals(7778, choice?.port)
    }

    @Test
    fun explicitTcpUsesLoopbackReversePort() {
        val choice = TransportSelector.select(TransportMode.TCP, true, "192.168.1.5", 7778)
        assertEquals(TransportKind.TCP, choice?.kind)
        assertEquals("127.0.0.1", choice?.host)
        assertEquals(7777, choice?.port)
    }

    @Test
    fun savedHostIsTrimmedAndRejectsBlank() {
        assertEquals(
            "10.0.2.2",
            TransportSelector.select(TransportMode.WIFI, false, " 10.0.2.2 ", 7778)?.host
        )
        assertNull(TransportSelector.select(TransportMode.WIFI, false, "   ", 7778))
    }
}