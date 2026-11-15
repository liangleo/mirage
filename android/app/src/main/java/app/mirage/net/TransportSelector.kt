package app.mirage.net

object TransportSelector {
    private const val TCP_HOST = "127.0.0.1"
    private const val TCP_PORT = 7777

    fun select(
        mode: TransportMode,
        hasAccessory: Boolean,
        savedHost: String?,
        savedPort: Int
    ): TransportChoice? {
        val wifiHost = savedHost?.trim()?.takeIf { it.isNotEmpty() && savedPort in 1..65535 }
        return when (mode) {
            TransportMode.AUTO -> when {
                hasAccessory -> TransportChoice(TransportKind.USB)
                wifiHost != null -> TransportChoice(TransportKind.WIFI, wifiHost, savedPort)
                else -> TransportChoice(TransportKind.TCP, TCP_HOST, TCP_PORT)
            }
            TransportMode.USB ->
                if (hasAccessory) TransportChoice(TransportKind.USB)
                else TransportChoice(TransportKind.WAIT_USB)
            TransportMode.WIFI ->
                wifiHost?.let { TransportChoice(TransportKind.WIFI, it, savedPort) }
            TransportMode.TCP -> TransportChoice(TransportKind.TCP, TCP_HOST, TCP_PORT)
        }
    }
}