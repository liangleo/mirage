package app.mirage.net

import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.io.InputStream
import java.io.OutputStream
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

class TlsStreamConnection(
    host: String,
    port: Int,
    fingerprint: ByteArray
) : StreamConnection {
    private val raw = Socket().apply {
        connect(InetSocketAddress(host, port), 5_000)
        tcpNoDelay = true
    }

    private val ssl: SSLSocket

    init {
        val pinning = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = Unit

            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val leaf = chain?.firstOrNull() ?: throw CertificateException("服务器未提供证书")
                val actual = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
                if (!MessageDigest.isEqual(actual, fingerprint)) {
                    throw CertificateException("证书指纹不匹配")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val context = SSLContext.getInstance("TLS").apply {
            init(null, arrayOf(pinning), null)
        }
        ssl = (context.socketFactory.createSocket(raw, host, port, true) as SSLSocket).apply {
            sslParameters = sslParameters.apply { endpointIdentificationAlgorithm = null }
            startHandshake()
        }
    }

    override val input: InputStream = ssl.inputStream
    override val output: OutputStream = ssl.outputStream

    val negotiatedProtocol: String get() = ssl.session.protocol

    override fun prepareRead() {
        ssl.soTimeout = 1_000
    }

    override fun close() {
        try {
            ssl.close()
        } catch (_: Exception) {
        }
        try {
            raw.close()
        } catch (_: Exception) {
        }
    }
}