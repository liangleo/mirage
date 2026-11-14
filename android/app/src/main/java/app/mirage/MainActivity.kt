package app.mirage

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Surface
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import app.mirage.net.Hello
import app.mirage.net.MirageClient
import app.mirage.net.SessionConfig
import app.mirage.net.StatsSnapshot
import app.mirage.net.StreamStats
import app.mirage.net.VideoFrame
import app.mirage.ui.AspectSurfaceView
import app.mirage.ui.ConnectScreen
import app.mirage.ui.VideoView
import app.mirage.video.VideoDecoder
import kotlinx.coroutines.delay
import java.security.SecureRandom

class MainActivity : ComponentActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var decoder: VideoDecoder? = null

    @Volatile
    private var surface: Surface? = null

    @Volatile
    private var config: SessionConfig? = null

    @Volatile
    private var pendingKeyframe: VideoFrame? = null

    private var surfaceView: AspectSurfaceView? = null
    private var client: MirageClient? = null
    private val stats = StreamStats()

    private var lastHost: String? = null
    private var lastPort: Int = 0
    private var autoReconnectEnabled = false
    private var manualDisconnect = false
    private var reconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null

    private var connected by mutableStateOf(false)
    private var status by mutableStateOf("未连接")

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                if (connected) {
                    StreamingScreen(
                        stats = stats,
                        status = status,
                        onSurfaceReady = { view, newSurface ->
                            surfaceView = view
                            surface = newSurface
                            maybeStartDecoder()
                        },
                        onSurfaceDestroyed = {
                            decoder?.release()
                            decoder = null
                            surface = null
                        },
                        onDisconnect = { disconnect() }
                    )
                } else {
                    ConnectScreen(status = status, onConnect = { host, port ->
                        connect(host, port)
                    })
                }
            }
        }
    }

    override fun onDestroy() {
        disconnect()
        super.onDestroy()
    }

    private fun connect(host: String, port: Int, isReconnect: Boolean = false) {
        lastHost = host
        lastPort = port
        if (!isReconnect) {
            autoReconnectEnabled = false
            manualDisconnect = false
            reconnectAttempts = 0
        }
        status = if (isReconnect) "重连中…（第 $reconnectAttempts 次）" else "连接中…"

        client?.close()
        client = null

        val newClient = MirageClient(host, port, buildHello(), stats, object : MirageClient.Listener {
            override fun onConfig(newConfig: SessionConfig) {
                mainHandler.post {
                    autoReconnectEnabled = true
                    reconnectAttempts = 0
                    config = newConfig
                    status = "已连接 ${newConfig.width}x${newConfig.height}@${newConfig.fps}"
                    connected = true
                    maybeStartDecoder()
                }
            }

            override fun onVideo(frame: VideoFrame) {
                val currentDecoder = decoder
                if (currentDecoder != null) {
                    currentDecoder.submit(frame)
                } else if (frame.header.flags and 1 != 0) {
                    pendingKeyframe = frame
                }
            }

            override fun onClosed(reason: String) {
                mainHandler.post { handleConnectionClosed(reason) }
            }
        })
        client = newClient
        newClient.connect()
    }

    private fun handleConnectionClosed(reason: String) {
        client = null
        decoder?.release()
        decoder = null
        config = null
        pendingKeyframe = null

        if (manualDisconnect || !autoReconnectEnabled || isFinishing || isDestroyed) {
            if (!manualDisconnect) {
                status = reason
            }
            connected = false
            return
        }

        status = "连接断开（$reason），自动重连中…"
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        val host = lastHost ?: return
        if (host.isBlank() || lastPort <= 0) return

        reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        reconnectAttempts++
        val delayMs = (500L * (1 shl minOf(reconnectAttempts - 1, 3))).coerceAtMost(5_000L)

        val runnable = Runnable {
            if (isFinishing || isDestroyed || !autoReconnectEnabled || manualDisconnect) return@Runnable
            connect(host, lastPort, isReconnect = true)
        }
        reconnectRunnable = runnable
        mainHandler.postDelayed(runnable, delayMs)
    }

    private fun disconnect() {
        manualDisconnect = true
        autoReconnectEnabled = false
        reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        reconnectRunnable = null
        client?.close()
        client = null
        decoder?.release()
        decoder = null
        config = null
        pendingKeyframe = null
        surface = null
        surfaceView = null
        connected = false
        status = "未连接"
    }

    private fun maybeStartDecoder() {
        val currentConfig = config ?: return
        val currentSurface = surface ?: return
        if (decoder != null) return

        surfaceView?.apply {
            videoWidth = currentConfig.width
            videoHeight = currentConfig.height
        }
        val newDecoder = VideoDecoder(
            surface = currentSurface,
            config = currentConfig,
            stats = stats,
            onError = { message -> mainHandler.post { status = message } },
            onNeedKeyframe = { client?.requestKeyframe() }
        )
        decoder = newDecoder
        newDecoder.start()
        pendingKeyframe?.let {
            newDecoder.submit(it)
            pendingKeyframe = null
        }
        client?.requestKeyframe()
    }

    private fun buildHello(): Hello {
        @Suppress("DEPRECATION")
        val currentDisplay = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display ?: windowManager.defaultDisplay
        } else {
            windowManager.defaultDisplay
        }

        val metrics = DisplayMetrics()
        if (currentDisplay != null) {
            currentDisplay.getRealMetrics(metrics)
        } else {
            @Suppress("DEPRECATION")
            metrics.setTo(resources.displayMetrics)
        }

        val rotation = when (currentDisplay?.rotation ?: Surface.ROTATION_0) {
            Surface.ROTATION_90 -> 1
            Surface.ROTATION_180 -> 2
            Surface.ROTATION_270 -> 3
            else -> 0
        }
        return Hello(
            protoVersion = 1,
            clientVersion = 1,
            deviceID = deviceID(),
            screenWidth = metrics.widthPixels,
            screenHeight = metrics.heightPixels,
            xdpi = metrics.xdpi.toInt(),
            ydpi = metrics.ydpi.toInt(),
            maxFPS = (currentDisplay?.refreshRate ?: 60f).toInt(),
            codecs = 1,
            features = 0,
            rotation = rotation,
            name = Build.MODEL ?: "Android"
        )
    }

    private fun deviceID(): ByteArray {
        val preferences = getSharedPreferences("mirage", Context.MODE_PRIVATE)
        val stored = preferences.getString("device_id", null)
        if (stored != null) {
            return stored.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        }
        val bytes = ByteArray(16)
        SecureRandom().nextBytes(bytes)
        preferences.edit()
            .putString("device_id", bytes.joinToString("") { "%02x".format(it) })
            .apply()
        return bytes
    }
}

@Composable
private fun StreamingScreen(
    stats: StreamStats,
    status: String,
    onSurfaceReady: (AspectSurfaceView, Surface) -> Unit,
    onSurfaceDestroyed: () -> Unit,
    onDisconnect: () -> Unit
) {
    var snapshot by remember { mutableStateOf(StatsSnapshot()) }
    LaunchedEffect(Unit) {
        while (true) {
            snapshot = stats.snapshot()
            delay(500)
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        VideoView(
            onSurfaceReady = onSurfaceReady,
            onSurfaceDestroyed = onSurfaceDestroyed
        )
        Column(
            modifier = Modifier
                .align(Alignment.TopStart)
                .background(Color.Black.copy(alpha = 0.5f))
                .padding(12.dp)
        ) {
            val e2e = if (snapshot.e2eMs >= 0) {
                " · e2e≈${snapshot.e2eMs + snapshot.decodeMs} ms"
            } else {
                ""
            }
            Text(
                "${snapshot.fps} fps · ${snapshot.decodeMs} ms · " +
                    "%.1f Mbps · drop ${snapshot.dropped}%s".format(snapshot.bitrateMbps, e2e),
                color = Color.White
            )
            Text(status, color = Color.White)
        }
        TextButton(
            onClick = onDisconnect,
            modifier = Modifier
                .align(Alignment.TopEnd)
                .padding(16.dp)
        ) {
            Text("断开")
        }
    }
}