package app.mirage.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log

class MdnsDiscovery(context: Context) {
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val mainHandler = Handler(Looper.getMainLooper())
    private var listener: NsdManager.DiscoveryListener? = null

    fun start(
        onFound: (host: String, port: Int, attributes: Map<String, String>) -> Unit,
        onError: (String) -> Unit
    ) {
        stop()
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) = Unit

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                if (!serviceInfo.serviceType.contains("_mirage._tcp")) return
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                        mainHandler.post { onError("解析服务失败：$errorCode") }
                    }

                    override fun onServiceResolved(info: NsdServiceInfo) {
                        @Suppress("DEPRECATION")
                        val host = info.host?.hostAddress
                        val port = info.port
                        val attributes = info.attributes
                            ?.mapValues { (_, value) -> String(value, Charsets.UTF_8) }
                            .orEmpty()
                        stop()
                        if (host != null && port > 0) {
                            mainHandler.post { onFound(host, port, attributes) }
                        } else {
                            mainHandler.post { onError("服务缺少地址") }
                        }
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit

            override fun onDiscoveryStopped(serviceType: String) = Unit

            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w("Mirage", "mDNS start failed: $errorCode")
                stop()
                mainHandler.post { onError("mDNS 发现失败：$errorCode") }
            }

            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w("Mirage", "mDNS stop failed: $errorCode")
            }
        }
        listener = discovery
        nsd.discoverServices("_mirage._tcp", NsdManager.PROTOCOL_DNS_SD, discovery)
    }

    fun stop() {
        val current = listener ?: return
        listener = null
        try {
            nsd.stopServiceDiscovery(current)
        } catch (_: Exception) {
        }
    }
}