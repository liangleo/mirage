package app.mirage.session

import app.mirage.net.TransportMode

data class ReconnectOverlay(val message: String, val remainSec: Int)

data class SessionUiState(
    val inStream: Boolean = false,
    val connected: Boolean = false,
    val connecting: Boolean = false,
    val status: String = "未连接",
    val transportInfo: String = "",
    val transportName: String = "",
    val transportMode: TransportMode = TransportMode.AUTO,
    val savedHost: String = "",
    val savedPort: Int = 0,
    val savedFingerprint: String = "",
    val phoneWidth: Int = 0,
    val phoneHeight: Int = 0,
    val videoWidth: Int = 0,
    val videoHeight: Int = 0,
    val inputCaps: Int = 0,
    val inputAllowed: Boolean = false,
    val inputReason: String? = null,
    val keyboardVisible: Boolean = false,
    val debugOn: Boolean = false,
    val inputOn: Boolean = true,
    val overlay: ReconnectOverlay? = null
)