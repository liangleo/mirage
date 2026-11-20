package app.mirage.session

import app.mirage.net.SessionConfig
import app.mirage.net.TransportKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionMachineTest {
    private val config = SessionConfig(
        width = 2880,
        height = 1920,
        fps = 60,
        codec = 1,
        bitrate = 20_000_000,
        rotation = 0,
        inputCaps = 7
    )

    private fun selectAndOpen(): MachineState =
        reduce(
            reduce(MachineState(), SessionEvent.Connect),
            SessionEvent.Select(TransportKind.WIFI)
        )

    @Test
    fun connectFromIdleSelectsAndBumpsGeneration() {
        val state = reduce(MachineState(), SessionEvent.Connect)

        assertEquals(SessionState.Selecting, state.state)
        assertEquals(0, state.attempts)
        assertEquals(1, state.generation)
    }

    @Test
    fun selectWaitUsbStaysIdleAndPolls() {
        val state = reduce(
            reduce(MachineState(), SessionEvent.Connect),
            SessionEvent.Select(TransportKind.WAIT_USB)
        )

        assertEquals(SessionState.Idle, state.state)
        assertTrue(state.actions.contains(SessionAction.PollUsb))
    }

    @Test
    fun selectTransportEntersConnecting() {
        val state = selectAndOpen()

        assertEquals(SessionState.Connecting, state.state)
        assertTrue(state.actions.contains(SessionAction.OpenTransport))
    }

    @Test
    fun configStartsDecoderAndRequestsKeyframe() {
        val state = reduce(selectAndOpen(), SessionEvent.Config(config))

        assertEquals(SessionState.Streaming(config), state.state)
        assertEquals(0, state.attempts)
        assertTrue(state.actions.contains(SessionAction.StartDecoder))
        assertTrue(state.actions.contains(SessionAction.RequestKeyframe))
    }

    @Test
    fun closedBelowLimitEntersRecoveringWithBackoff() {
        val streaming = reduce(selectAndOpen(), SessionEvent.Config(config))
        val state = reduce(streaming, SessionEvent.Closed("连接已断开"))

        assertEquals(SessionState.Recovering("连接已断开"), state.state)
        assertEquals(1, state.attempts)
        assertEquals(500, state.backoffMs)
        assertTrue(state.actions.contains(SessionAction.CloseTransport))
        assertTrue(state.actions.contains(SessionAction.StopDecoder))
    }

    @Test
    fun closedAboveLimitStops() {
        var state = MachineState(attempts = 10, state = SessionState.Streaming(config))
        state = reduce(state, SessionEvent.Closed("连接已断开"))

        assertEquals(SessionState.Stopped, state.state)
        assertEquals(11, state.attempts)
    }

    @Test
    fun retryFromRecoveringSelects() {
        val recovering = reduce(
            reduce(selectAndOpen(), SessionEvent.Config(config)),
            SessionEvent.Closed("连接已断开")
        )
        val state = reduce(recovering, SessionEvent.Retry)

        assertEquals(SessionState.Selecting, state.state)
        assertEquals(recovering.generation + 1, state.generation)
    }

    @Test
    fun disconnectStopsAndCloses() {
        val streaming = reduce(selectAndOpen(), SessionEvent.Config(config))
        val state = reduce(streaming, SessionEvent.Disconnect)

        assertEquals(SessionState.Stopped, state.state)
        assertTrue(state.actions.contains(SessionAction.CloseTransport))
        assertTrue(state.actions.contains(SessionAction.StopDecoder))
    }

    @Test
    fun transportChangedSelects() {
        val streaming = reduce(selectAndOpen(), SessionEvent.Config(config))
        val state = reduce(streaming, SessionEvent.TransportChanged)

        assertEquals(SessionState.Selecting, state.state)
        assertTrue(state.actions.contains(SessionAction.CloseTransport))
    }

    @Test
    fun permanentErrorStopsWithoutRetry() {
        val streaming = reduce(selectAndOpen(), SessionEvent.Config(config))
        val state = reduce(streaming, SessionEvent.PermanentError("证书指纹不匹配"))

        assertEquals(SessionState.Stopped, state.state)
        assertEquals(0, state.attempts)
    }

    @Test
    fun staleConnectionClosedIsIgnored() {
        val state = reduce(MachineState(), SessionEvent.Closed("连接已断开"))

        assertEquals(SessionState.Idle, state.state)
        assertEquals(0, state.attempts)
    }

    @Test
    fun screenChangedKeepsStreamingWithoutActions() {
        val streaming = reduce(selectAndOpen(), SessionEvent.Config(config))
        val state = reduce(streaming, SessionEvent.ScreenChanged(1920, 2880, 1))

        assertEquals(SessionState.Streaming(config), state.state)
        assertTrue(state.actions.isEmpty())
    }
}