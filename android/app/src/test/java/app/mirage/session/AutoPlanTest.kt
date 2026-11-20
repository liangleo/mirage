package app.mirage.session

import app.mirage.net.TransportKind
import app.mirage.net.TransportMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AutoPlanTest {
    @Test
    fun autoPrefersUsb() {
        val plan = AutoPlan.select(TransportMode.AUTO, 0, true, "192.168.1.10", 7778)
        assertEquals(TransportKind.USB, plan?.kind)
    }

    @Test
    fun autoUsesWifiWhenConfigured() {
        val plan = AutoPlan.select(TransportMode.AUTO, 0, false, "192.168.1.10", 7778)
        assertEquals(TransportKind.WIFI, plan?.kind)
        assertEquals("192.168.1.10", plan?.host)
        assertEquals(7778, plan?.port)
    }

    @Test
    fun autoFallsBackToTcp() {
        val plan = AutoPlan.select(TransportMode.AUTO, 0, false, null, 0)
        assertEquals(TransportKind.TCP, plan?.kind)
        assertEquals("127.0.0.1", plan?.host)
        assertEquals(7777, plan?.port)
    }

    @Test
    fun stageOneSkipsUsb() {
        val plan = AutoPlan.select(TransportMode.AUTO, 1, true, "192.168.1.10", 7778)
        assertEquals(TransportKind.WIFI, plan?.kind)
    }

    @Test
    fun stageTwoIsTcp() {
        val plan = AutoPlan.select(TransportMode.AUTO, 2, true, "192.168.1.10", 7778)
        assertEquals(TransportKind.TCP, plan?.kind)
    }

    @Test
    fun explicitWifiNeverSwitchesToUsb() {
        assertFalse(AutoPlan.shouldPollUsb(TransportMode.WIFI, true, TransportKind.WIFI))
        assertFalse(AutoPlan.shouldSendUsbRequest(TransportMode.WIFI, true, TransportKind.WIFI))
    }

    @Test
    fun autoOnWifiPollsAndRequestsUsb() {
        assertTrue(AutoPlan.shouldPollUsb(TransportMode.AUTO, true, TransportKind.WIFI))
        assertTrue(AutoPlan.shouldSendUsbRequest(TransportMode.AUTO, true, TransportKind.WIFI))
    }

    @Test
    fun autoOnUsbDoesNotRequestUsb() {
        assertFalse(AutoPlan.shouldPollUsb(TransportMode.AUTO, true, TransportKind.USB))
        assertFalse(AutoPlan.shouldSendUsbRequest(TransportMode.AUTO, true, TransportKind.USB))
    }

    @Test
    fun usbSwitchStopsAfterThreeFailures() {
        var state = UsbSwitchState()
        state = UsbSwitchPolicy.onFailure(state)
        state = UsbSwitchPolicy.onFailure(state)
        assertFalse(state.disabled)

        state = UsbSwitchPolicy.onFailure(state)
        assertTrue(state.disabled)
        assertEquals(3, state.failures)
    }

    @Test
    fun usbDetachResetsSwitchFailures() {
        var state = UsbSwitchState(failures = 3, disabled = true)
        state = UsbSwitchPolicy.onDetach(state)
        assertEquals(0, state.failures)
        assertFalse(state.disabled)
    }

    @Test
    fun permissionDeniedIsPermanent() {
        assertTrue(UsbSwitchPolicy.permissionDeniedIsPermanent())
    }
}