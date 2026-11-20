package app.mirage.session

import app.mirage.ui.MirageStrings
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DockStateTest {
    @Test
    fun disconnectFirstTapArmsAndShowsDanger() {
        val result = DockState().apply(DockIntent.RequestDisconnect(1_000))

        assertTrue(result.state.disconnectArmed)
        assertEquals(listOf(MirageStrings.DISCONNECT_CONFIRM), result.toasts)
        assertFalse(result.disconnect)
    }

    @Test
    fun disconnectSecondTapWithin3sConfirms() {
        val armed = DockState().apply(DockIntent.RequestDisconnect(1_000)).state
        val result = armed.apply(DockIntent.RequestDisconnect(3_500))

        assertTrue(result.disconnect)
        assertFalse(result.state.disconnectArmed)
    }

    @Test
    fun disconnectArmExpiresAfter3s() {
        val armed = DockState().apply(DockIntent.RequestDisconnect(1_000)).state
        val result = armed.apply(DockIntent.Tick(4_500))

        assertFalse(result.state.disconnectArmed)
        assertFalse(result.disconnect)
    }

    @Test
    fun inputToggleFlipsAndEmitsToast() {
        val off = DockState(inputOn = true).apply(DockIntent.ToggleInput)
        assertFalse(off.state.inputOn)
        assertEquals(listOf(MirageStrings.TOUCH_OFF), off.toasts)

        val on = off.state.apply(DockIntent.ToggleInput)
        assertTrue(on.state.inputOn)
        assertEquals(listOf(MirageStrings.TOUCH_ON), on.toasts)
    }

    @Test
    fun gearExpandsAndClosesWithoutChangingToggles() {
        val opened = DockState(debugOn = true, inputOn = false).apply(DockIntent.ToggleOpen)
        assertTrue(opened.state.open)
        assertTrue(opened.state.debugOn)
        assertFalse(opened.state.inputOn)
        assertTrue(opened.toasts.isEmpty())

        val closed = opened.state.apply(DockIntent.ToggleOpen)
        assertFalse(closed.state.open)
    }
}