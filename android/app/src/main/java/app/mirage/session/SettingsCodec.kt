package app.mirage.session

import app.mirage.net.TransportMode

data class PersistedSettings(
    val host: String = "",
    val port: Int = 0,
    val fingerprint: String = "",
    val deviceIdHex: String = "",
    val transportMode: TransportMode = TransportMode.AUTO,
    val debugOn: Boolean = false,
    val inputOn: Boolean = true
)

object SettingsCodec {
    fun decode(map: Map<String, *>): PersistedSettings {
        val mode = (map["transportMode"] as? String)
            ?.let { runCatching { TransportMode.valueOf(it) }.getOrNull() }
            ?: TransportMode.AUTO
        return PersistedSettings(
            host = map["host"] as? String ?: "",
            port = (map["port"] as? Number)?.toInt() ?: 0,
            fingerprint = map["fingerprint"] as? String ?: "",
            deviceIdHex = map["device_id"] as? String ?: "",
            transportMode = mode,
            debugOn = map["debugOn"] as? Boolean ?: false,
            inputOn = map["inputOn"] as? Boolean ?: true
        )
    }

    fun encode(settings: PersistedSettings): Map<String, Any?> = mapOf(
        "host" to settings.host,
        "port" to settings.port,
        "fingerprint" to settings.fingerprint,
        "device_id" to settings.deviceIdHex,
        "transportMode" to settings.transportMode.name,
        "debugOn" to settings.debugOn,
        "inputOn" to settings.inputOn
    )

    fun shouldPersistPairing(isWifi: Boolean, success: Boolean): Boolean = isWifi && success
}