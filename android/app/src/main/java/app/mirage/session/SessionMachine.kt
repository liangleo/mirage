package app.mirage.session

import app.mirage.net.TransportKind

private val CLOSE_AND_STOP = listOf(SessionAction.CloseTransport, SessionAction.StopDecoder)

fun reduce(state: MachineState, event: SessionEvent): MachineState = when (event) {
    SessionEvent.Connect -> when (state.state) {
        SessionState.Idle, SessionState.Stopped -> state.copy(
            state = SessionState.Selecting,
            attempts = 0,
            generation = state.generation + 1,
            backoffMs = 0,
            actions = emptyList()
        )
        else -> state.copy(actions = emptyList())
    }

    is SessionEvent.Select -> when {
        state.state != SessionState.Selecting -> state.copy(actions = emptyList())
        event.kind == TransportKind.WAIT_USB -> state.copy(
            state = SessionState.Idle,
            actions = listOf(SessionAction.PollUsb)
        )
        else -> state.copy(
            state = SessionState.Connecting,
            actions = listOf(SessionAction.OpenTransport)
        )
    }

    is SessionEvent.Config -> when (state.state) {
        SessionState.Connecting, is SessionState.Streaming -> state.copy(
            state = SessionState.Streaming(event.config),
            attempts = 0,
            backoffMs = 0,
            actions = listOf(SessionAction.StartDecoder, SessionAction.RequestKeyframe)
        )
        else -> state.copy(actions = emptyList())
    }

    is SessionEvent.Closed -> when (state.state) {
        SessionState.Connecting, is SessionState.Streaming, is SessionState.Recovering -> {
            val attempts = state.attempts + 1
            if (ReconnectPolicy.innerExhausted(attempts)) {
                state.copy(
                    state = SessionState.Stopped,
                    attempts = attempts,
                    actions = CLOSE_AND_STOP
                )
            } else {
                state.copy(
                    state = SessionState.Recovering(event.reason),
                    attempts = attempts,
                    backoffMs = ReconnectPolicy.innerBackoffMs(attempts),
                    actions = CLOSE_AND_STOP
                )
            }
        }
        else -> state.copy(actions = emptyList())
    }

    SessionEvent.Retry -> when (state.state) {
        is SessionState.Recovering -> state.copy(
            state = SessionState.Selecting,
            generation = state.generation + 1,
            actions = emptyList()
        )
        else -> state.copy(actions = emptyList())
    }

    SessionEvent.Disconnect -> if (state.state == SessionState.Stopped) {
        state.copy(actions = emptyList())
    } else {
        state.copy(state = SessionState.Stopped, backoffMs = 0, actions = CLOSE_AND_STOP)
    }

    SessionEvent.TransportChanged -> state.copy(
        state = SessionState.Selecting,
        attempts = 0,
        backoffMs = 0,
        actions = CLOSE_AND_STOP
    )

    is SessionEvent.ScreenChanged -> state.copy(actions = emptyList())

    is SessionEvent.PermanentError -> state.copy(
        state = SessionState.Stopped,
        backoffMs = 0,
        actions = CLOSE_AND_STOP
    )
}