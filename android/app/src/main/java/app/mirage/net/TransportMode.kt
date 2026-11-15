package app.mirage.net

enum class TransportMode { AUTO, USB, WIFI, TCP }

enum class TransportKind { USB, WIFI, TCP, WAIT_USB }

data class TransportChoice(
    val kind: TransportKind,
    val host: String? = null,
    val port: Int = 0
)