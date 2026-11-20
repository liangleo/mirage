package app.mirage.session

import app.mirage.net.TransportKind
import app.mirage.net.TransportMode

data class TransportPlan(val kind: TransportKind, val host: String? = null, val port: Int = 0)

object AutoPlan {
    private const val TCP_HOST = "127.0.0.1"
    private const val TCP_PORT = 7777

    fun select(
        mode: TransportMode,
        stage: Int,
        hasAccessory: Boolean,
        host: String?,
        port: Int
    ): TransportPlan? {
        val wifiHost = host?.trim()?.takeIf { it.isNotEmpty() && port in 1..65535 }
        return when (mode) {
            TransportMode.AUTO -> when {
                stage <= 0 && hasAccessory -> TransportPlan(TransportKind.USB)
                stage <= 1 && wifiHost != null ->
                    TransportPlan(TransportKind.WIFI, wifiHost, port)
                else -> TransportPlan(TransportKind.TCP, TCP_HOST, TCP_PORT)
            }

            TransportMode.USB ->
                if (hasAccessory) TransportPlan(TransportKind.USB)
                else TransportPlan(TransportKind.WAIT_USB)

            TransportMode.WIFI ->
                wifiHost?.let { TransportPlan(TransportKind.WIFI, it, port) }

            TransportMode.TCP -> TransportPlan(TransportKind.TCP, TCP_HOST, TCP_PORT)
        }
    }

    fun nextStage(stage: Int): Int = minOf(stage + 1, 2)

    fun shouldPollUsb(mode: TransportMode, streaming: Boolean, kind: TransportKind): Boolean =
        shouldSendUsbRequest(mode, streaming, kind)

    fun shouldSendUsbRequest(mode: TransportMode, streaming: Boolean, kind: TransportKind): Boolean =
        mode == TransportMode.AUTO && streaming &&
            (kind == TransportKind.WIFI || kind == TransportKind.TCP)
}

data class UsbSwitchState(val failures: Int = 0, val disabled: Boolean = false)

object UsbSwitchPolicy {
    const val MAX_FAILURES = 3

    fun onFailure(state: UsbSwitchState): UsbSwitchState {
        if (state.disabled) return state
        val failures = state.failures + 1
        return state.copy(failures = failures, disabled = failures >= MAX_FAILURES)
    }

    fun onDetach(state: UsbSwitchState): UsbSwitchState = UsbSwitchState()

    fun permissionDeniedIsPermanent(): Boolean = true
}