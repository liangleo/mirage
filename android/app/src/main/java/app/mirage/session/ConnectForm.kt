package app.mirage.session

import app.mirage.net.PairingPayload
import app.mirage.net.TransportMode

data class ConnectFields(val host: String, val port: Int, val fingerprintHex: String)

sealed interface ConnectValidation {
    data class Valid(val fields: ConnectFields) : ConnectValidation
    data class Invalid(val message: String) : ConnectValidation
}

object ConnectForm {
    fun defaultPort(mode: TransportMode): Int =
        if (mode == TransportMode.TCP) 7777 else 7778

    fun fromPairing(link: String): ConnectFields? {
        val payload = PairingPayload.parse(link) ?: return null
        return ConnectFields(payload.host, payload.port, payload.fingerprintHex)
    }

    fun validate(
        hostText: String,
        portText: String,
        fingerprintHex: String,
        mode: TransportMode
    ): ConnectValidation {
        if (mode == TransportMode.TCP) {
            return ConnectValidation.Valid(ConnectFields("127.0.0.1", 7777, ""))
        }
        val host = hostText.trim()
        if (host.isEmpty()) {
            if (mode == TransportMode.AUTO || mode == TransportMode.USB) {
                return ConnectValidation.Valid(ConnectFields("", 0, fingerprintHex))
            }
            return ConnectValidation.Invalid("请填写主机与端口")
        }
        val port = portText.toIntOrNull()
        if (port == null || port !in 1..65535) {
            return ConnectValidation.Invalid("地址或端口无效")
        }
        if (mode == TransportMode.WIFI && !isLoopback(host) &&
            PairingPayload.decodeFingerprint(fingerprintHex) == null
        ) {
            return ConnectValidation.Invalid("Wi-Fi 连接需要配对指纹，请扫码或粘贴配对链接")
        }
        return ConnectValidation.Valid(ConnectFields(host, port, fingerprintHex))
    }

    fun isLoopback(host: String): Boolean =
        host == "localhost" || host == "::1" || host.startsWith("127.")
}