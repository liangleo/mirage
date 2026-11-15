package app.mirage.net

import java.net.URLDecoder
import java.net.URLEncoder
import java.util.UUID

data class PairingPayload(
    val host: String,
    val port: Int,
    val fingerprint: ByteArray,
    val name: String,
    val deviceID: String
) {
    val fingerprintHex: String get() = fingerprint.joinToString("") { "%02x".format(it) }

    fun encodeURL(): String? {
        if (fingerprint.size != 32 || port !in 1..65535) return null
        val query = listOf(
            "v" to "1",
            "host" to host,
            "port" to port.toString(),
            "fp" to fingerprintHex,
            "name" to name,
            "id" to deviceID
        ).joinToString("&") { (key, value) -> "$key=${encode(value)}" }
        return "mirage://pair?$query"
    }

    companion object {
        fun parse(url: String): PairingPayload? {
            val trimmed = url.trim()
            if (!trimmed.startsWith("mirage://pair?", ignoreCase = true)) return null
            val query = trimmed.substringAfter('?', "")
            val values = query.split('&').mapNotNull { pair ->
                val index = pair.indexOf('=')
                if (index <= 0) null else decode(pair.substring(0, index)) to decode(pair.substring(index + 1))
            }.toMap()

            if (values["v"] != "1") return null
            val host = values["host"]?.takeIf { it.isNotEmpty() } ?: return null
            val port = values["port"]?.toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val fingerprint = decodeFingerprint(values["fp"]) ?: return null
            val deviceID = values["id"]?.let { runCatching { UUID.fromString(it) }.getOrNull() } ?: return null
            return PairingPayload(host, port, fingerprint, values["name"] ?: host, deviceID.toString())
        }

        fun decodeFingerprint(hex: String?): ByteArray? {
            if (hex == null || hex.length != 64) return null
            return runCatching {
                ByteArray(32) { index -> hex.substring(index * 2, index * 2 + 2).toInt(16).toByte() }
            }.getOrNull()
        }

        private fun encode(value: String): String = URLEncoder.encode(value, "UTF-8")

        private fun decode(value: String): String = URLDecoder.decode(value, "UTF-8")
    }
}