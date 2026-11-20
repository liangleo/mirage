package app.mirage.ui

import app.mirage.R
import org.junit.Assert.assertEquals
import org.junit.Test

class DockIconsTest {
    @Test
    fun inputOnUsesActiveIcon() {
        assertEquals(R.drawable.ic_input_active, iconRes(DockAction.INPUT, DockVisualState.ACTIVE))
    }

    @Test
    fun inputOffUsesDisabledIcon() {
        assertEquals(R.drawable.ic_input_disabled, iconRes(DockAction.INPUT, DockVisualState.DISABLED))
    }

    @Test
    fun disconnectFirstTapUsesActiveIcon() {
        assertEquals(
            R.drawable.ic_disconnect_active,
            iconRes(DockAction.DISCONNECT, DockVisualState.ACTIVE)
        )
    }

    @Test
    fun disconnectIdleUsesDisabledIcon() {
        assertEquals(
            R.drawable.ic_disconnect_disabled,
            iconRes(DockAction.DISCONNECT, DockVisualState.DISABLED)
        )
    }

    @Test
    fun settingsCollapsedUsesDisabledSettings() {
        assertEquals(
            R.drawable.ic_settings_disabled,
            iconRes(DockAction.SETTINGS, DockVisualState.DISABLED)
        )
    }
}