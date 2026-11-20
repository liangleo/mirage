package app.mirage.ui

import androidx.annotation.DrawableRes
import app.mirage.R

enum class DockAction { DEBUG, INPUT, KEYBOARD, DISCONNECT, SETTINGS, CLOSE }

enum class DockVisualState { NORMAL, DISABLED, ACTIVE, HOVER }

@DrawableRes
fun iconRes(action: DockAction, state: DockVisualState): Int = when (action) {
    DockAction.DEBUG -> when (state) {
        DockVisualState.ACTIVE -> R.drawable.ic_debug_active
        DockVisualState.DISABLED -> R.drawable.ic_debug_disabled
        DockVisualState.HOVER -> R.drawable.ic_debug_hover
        else -> R.drawable.ic_debug_normal
    }
    DockAction.INPUT -> when (state) {
        DockVisualState.ACTIVE -> R.drawable.ic_input_active
        DockVisualState.DISABLED -> R.drawable.ic_input_disabled
        DockVisualState.HOVER -> R.drawable.ic_input_hover
        else -> R.drawable.ic_input_normal
    }
    DockAction.KEYBOARD -> when (state) {
        DockVisualState.ACTIVE -> R.drawable.ic_keyboard_active
        DockVisualState.DISABLED -> R.drawable.ic_keyboard_disabled
        DockVisualState.HOVER -> R.drawable.ic_keyboard_hover
        else -> R.drawable.ic_keyboard_normal
    }
    DockAction.DISCONNECT -> when (state) {
        DockVisualState.ACTIVE -> R.drawable.ic_disconnect_active
        DockVisualState.NORMAL -> R.drawable.ic_disconnect_normal
        DockVisualState.HOVER -> R.drawable.ic_disconnect_hover
        else -> R.drawable.ic_disconnect_disabled
    }
    DockAction.SETTINGS -> when (state) {
        DockVisualState.NORMAL -> R.drawable.ic_settings_normal
        DockVisualState.ACTIVE -> R.drawable.ic_settings_active
        DockVisualState.HOVER -> R.drawable.ic_settings_hover
        else -> R.drawable.ic_settings_disabled
    }
    DockAction.CLOSE -> when (state) {
        DockVisualState.ACTIVE -> R.drawable.ic_close_active
        DockVisualState.DISABLED -> R.drawable.ic_close_disabled
        DockVisualState.HOVER -> R.drawable.ic_close_hover
        else -> R.drawable.ic_close_normal
    }
}