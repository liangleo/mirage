package app.mirage.session

import app.mirage.net.SessionConfig
import app.mirage.net.TransportKind

sealed interface SessionState {
    data object Idle : SessionState
    data object Selecting : SessionState
    data object Connecting : SessionState
    data class Streaming(val config: SessionConfig) : SessionState
    data class Recovering(val reason: String) : SessionState
    data object Stopped : SessionState
}

sealed interface SessionEvent {
    data object Connect : SessionEvent
    data class Select(val kind: TransportKind) : SessionEvent
    data class Config(val config: SessionConfig) : SessionEvent
    data class Closed(val reason: String) : SessionEvent
    data object Retry : SessionEvent
    data object Disconnect : SessionEvent
    data object TransportChanged : SessionEvent
    data class ScreenChanged(val width: Int, val height: Int, val rotation: Int) : SessionEvent
    data class PermanentError(val reason: String) : SessionEvent
}

sealed interface SessionAction {
    data object OpenTransport : SessionAction
    data object CloseTransport : SessionAction
    data object StartDecoder : SessionAction
    data object StopDecoder : SessionAction
    data object RequestKeyframe : SessionAction
    data object PollUsb : SessionAction
}

data class MachineState(
    val state: SessionState = SessionState.Idle,
    val attempts: Int = 0,
    val generation: Long = 0,
    val backoffMs: Long = 0,
    val actions: List<SessionAction> = emptyList()
)