package app.mirage.session

import app.mirage.ui.MirageStrings

data class DockState(
    val open: Boolean = false,
    val debugOn: Boolean = false,
    val inputOn: Boolean = true,
    val keyboardOn: Boolean = false,
    val disconnectArmedAt: Long = -1
) {
    val disconnectArmed: Boolean get() = disconnectArmedAt >= 0
}

sealed interface DockIntent {
    data object ToggleOpen : DockIntent
    data object ToggleDebug : DockIntent
    data object ToggleInput : DockIntent
    data object ToggleKeyboard : DockIntent
    data class RequestDisconnect(val nowMs: Long) : DockIntent
    data class Tick(val nowMs: Long) : DockIntent
}

data class DockResult(
    val state: DockState,
    val toasts: List<String> = emptyList(),
    val disconnect: Boolean = false
)

fun DockState.apply(intent: DockIntent): DockResult = when (intent) {
    DockIntent.ToggleOpen -> DockResult(copy(open = !open))
    DockIntent.ToggleDebug -> DockResult(
        copy(debugOn = !debugOn),
        listOf(if (debugOn) MirageStrings.DEBUG_OFF else MirageStrings.DEBUG_ON)
    )
    DockIntent.ToggleInput -> DockResult(
        copy(inputOn = !inputOn),
        listOf(if (inputOn) MirageStrings.TOUCH_OFF else MirageStrings.TOUCH_ON)
    )
    DockIntent.ToggleKeyboard -> DockResult(
        copy(keyboardOn = !keyboardOn),
        listOf(if (keyboardOn) MirageStrings.KEYBOARD_OFF else MirageStrings.KEYBOARD_ON)
    )
    is DockIntent.RequestDisconnect -> {
        val armed = disconnectArmed && intent.nowMs - disconnectArmedAt <= ARM_WINDOW_MS
        if (armed) {
            DockResult(copy(disconnectArmedAt = -1), disconnect = true)
        } else {
            DockResult(
                copy(disconnectArmedAt = intent.nowMs),
                listOf(MirageStrings.DISCONNECT_CONFIRM)
            )
        }
    }
    is DockIntent.Tick -> {
        if (disconnectArmed && intent.nowMs - disconnectArmedAt > ARM_WINDOW_MS) {
            DockResult(copy(disconnectArmedAt = -1))
        } else {
            DockResult(this)
        }
    }
}

const val ARM_WINDOW_MS = 3_000L