package app.mirage

import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.view.Surface
import android.view.WindowManager
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import app.mirage.net.Hello
import app.mirage.net.MirageClient
import app.mirage.net.SessionConfig
import app.mirage.net.StatsSnapshot
import app.mirage.net.StreamStats
import app.mirage.net.VideoFrame
import app.mirage.ui.AspectTextureView
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

    private var surfaceView: AspectTextureView? = null
    private var client: MirageClient? = null
    private val stats = StreamStats()

    private var savedHost = ""
    private var savedPort = 0
    private var lastHost: String? = null
    private var lastPort: Int = 0
    private var autoReconnectEnabled = false
    private var manualDisconnect = false
    private var reconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null
    private val maxReconnectAttempts = 10

    private var connected by mutableStateOf(false)
    private var connecting by mutableStateOf(false)
    private var toolbarVisible by mutableStateOf(true)
    private var showStats by mutableStateOf(false)
    private var phoneWidth by mutableStateOf(0)
    private var phoneHeight by mutableStateOf(0)
    private var videoWidth by mutableStateOf(0)
    private var videoHeight by mutableStateOf(0)
    private var status by mutableStateOf("未连接")
    private var showSettings by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val preferences = getSharedPreferences("mirage", Context.MODE_PRIVATE)
        savedHost = preferences.getString("host", "") ?: ""
        savedPort = preferences.getInt("port", 0)
        val metrics = screenMetrics()
        phoneWidth = metrics.widthPixels
        phoneHeight = metrics.heightPixels
        val configured = savedHost.isNotBlank() && savedPort > 0
        if (!configured) {
            status = "请先设置 Mac 地址"
            showSettings = true
        }

        setContent {
            MaterialTheme {
                Box(modifier = Modifier.fillMaxSize()) {
                    if (connected) {
                        Box(modifier = Modifier.fillMaxSize()) {
                            StreamingScreen(
                                stats = stats,
                                status = status,
                                showStats = showStats,
                                phoneWidth = phoneWidth,
                                phoneHeight = phoneHeight,
                                videoWidth = videoWidth,
                                videoHeight = videoHeight,
                                onSwipeDown = { toolbarVisible = true },
                                onSurfaceReady = { view, newSurface ->
                                    surfaceView = view
                                    surface = newSurface
                                    maybeStartDecoder()
                                },
                                onSurfaceDestroyed = {
                                    decoder?.release()
                                    decoder = null
                                    surface = null
                                }
                            )
                        }
                    } else {
                        DisconnectedScreen(
                            status = status,
                            connectEnabled = !connecting,
                            onConnect = {
                                if (savedHost.isNotBlank() && savedPort > 0) {
                                    connect(savedHost, savedPort)
                                } else {
                                    showSettings = true
                                }
                            }
                        )
                    }

                    LaunchedEffect(toolbarVisible, connected, showStats) {
                        if (connected && toolbarVisible) {
                            delay(3_000)
                            toolbarVisible = false
                        }
                    }

                    if (toolbarVisible || !connected) {
                        Row(
                            modifier = Modifier
                                .align(Alignment.TopCenter)
                                .fillMaxWidth()
                                .background(Color.Black.copy(alpha = 0.6f))
                                .padding(horizontal = 8.dp, vertical = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                IconButton(onClick = { showSettings = true }) {
                                    Icon(
                                        Icons.Default.Settings,
                                        contentDescription = "设置",
                                        modifier = Modifier.size(22.dp)
                                    )
                                }
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.padding(end = 8.dp)
                                ) {
                                    Icon(
                                        Icons.Default.Info,
                                        contentDescription = "调试",
                                        modifier = Modifier.size(20.dp)
                                    )
                                    Switch(
                                        checked = showStats,
                                        onCheckedChange = { showStats = it },
                                        modifier = Modifier
                                            .padding(start = 4.dp)
                                            .scale(0.8f)
                                    )
                                }
                            }
                            if (connected) {
                                IconButton(onClick = { disconnect() }) {
                                    Icon(
                                        Icons.Default.Close,
                                        contentDescription = "断开",
                                        modifier = Modifier.size(22.dp)
                                    )
                                }
                            }
                        }
                    }
                }

                if (showSettings) {
                    SettingsDialog(
                        initialHost = savedHost.ifBlank { "127.0.0.1" },
                        initialPort = if (savedPort > 0) savedPort.toString() else "7777",
                        onDismiss = { showSettings = false },
                        onSave = { host, port ->
                            savedHost = host
                            savedPort = port
                            preferences.edit()
                                .putString("host", host)
                                .putInt("port", port)
                                .apply()
                            showSettings = false
                            connect(host, port)
                        }
                    )
                }
            }
        }

        if (configured) {
            connect(savedHost, savedPort)
        }

        hideSystemBars()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemBars()
        }
    }

    private fun hideSystemBars() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun setKeepScreenOn(enabled: Boolean) {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
            autoReconnectEnabled = true
            manualDisconnect = false
            reconnectAttempts = 0
        }
        connecting = true
        status = if (isReconnect) "重连中…（第 $reconnectAttempts 次）" else "连接中…"

        client?.close()
        client = null

        val newClient = MirageClient(host, port, buildHello(), stats, object : MirageClient.Listener {
            override fun onConfig(newConfig: SessionConfig) {
                mainHandler.post {
                    autoReconnectEnabled = true
                    reconnectAttempts = 0
                    connecting = false
                    config = newConfig
                    videoWidth = newConfig.width
                    videoHeight = newConfig.height
                    setKeepScreenOn(true)
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
        setKeepScreenOn(false)
        decoder?.release()
        decoder = null
        config = null
        pendingKeyframe = null
        videoWidth = 0
        videoHeight = 0

        if (manualDisconnect || !autoReconnectEnabled || isFinishing || isDestroyed) {
            if (!manualDisconnect) {
                status = reason
            }
            connecting = false
            connected = false
            return
        }

        if (reconnectAttempts >= maxReconnectAttempts) {
            autoReconnectEnabled = false
            connecting = false
            connected = false
            status = "无法连接（$reason）"
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
        setKeepScreenOn(false)
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
        connecting = false
        connected = false
        status = "未连接"
    }

    private fun maybeStartDecoder() {
        val currentConfig = config ?: return
        val currentSurface = surface ?: return
        if (decoder != null) return

        surfaceView?.applyVideoSize(currentConfig.width, currentConfig.height)
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
        val currentDisplay = currentDisplay()
        val metrics = screenMetrics()

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

    @Suppress("DEPRECATION")
    private fun currentDisplay(): android.view.Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            display ?: windowManager.defaultDisplay
        } else {
            windowManager.defaultDisplay
        }

    private fun screenMetrics(): DisplayMetrics {
        val metrics = DisplayMetrics()
        val current = currentDisplay()
        if (current != null) {
            current.getRealMetrics(metrics)
        } else {
            @Suppress("DEPRECATION")
            metrics.setTo(resources.displayMetrics)
        }
        return metrics
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
private fun DisconnectedScreen(status: String, connectEnabled: Boolean, onConnect: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("Mirage", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(16.dp))
        Text(status)
        Spacer(Modifier.height(24.dp))
        Button(onClick = onConnect, enabled = connectEnabled) {
            Text("连接")
        }
    }
}

@Composable
private fun SettingsDialog(
    initialHost: String,
    initialPort: String,
    onDismiss: () -> Unit,
    onSave: (String, Int) -> Unit
) {
    var host by remember { mutableStateOf(initialHost) }
    var port by remember { mutableStateOf(initialPort) }
    var error by remember { mutableStateOf<String?>(null) }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("连接设置") },
        text = {
            Column {
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("Mac 地址") },
                    singleLine = true
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it },
                    label = { Text("端口") },
                    singleLine = true
                )
                error?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val parsedPort = port.toIntOrNull()
                if (host.isBlank() || parsedPort == null || parsedPort <= 0) {
                    error = "地址或端口无效"
                } else {
                    onSave(host.trim(), parsedPort)
                }
            }) {
                Text("保存并连接")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("取消")
            }
        }
    )
}

@Composable
private fun StreamingScreen(
    stats: StreamStats,
    status: String,
    showStats: Boolean,
    phoneWidth: Int,
    phoneHeight: Int,
    videoWidth: Int,
    videoHeight: Int,
    onSwipeDown: () -> Unit,
    onSurfaceReady: (AspectTextureView, Surface) -> Unit,
    onSurfaceDestroyed: () -> Unit
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
        Box(
            modifier = Modifier
                .fillMaxSize()
                .pointerInput(Unit) {
                    var startY = 0f
                    var totalDrag = 0f
                    detectVerticalDragGestures(
                        onDragStart = { offset ->
                            startY = offset.y
                            totalDrag = 0f
                        },
                        onVerticalDrag = { _, dragAmount ->
                            totalDrag += dragAmount
                        },
                        onDragEnd = {
                            if (startY < size.height * 0.2f && totalDrag > 80.dp.toPx()) {
                                onSwipeDown()
                            }
                        }
                    )
                }
        )
        if (showStats) {
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .background(Color.Black.copy(alpha = 0.5f))
                    .padding(12.dp)
            ) {
                val e2e = if (snapshot.e2eMs >= 0) {
                    " · e2e≈${snapshot.e2eMs + snapshot.decodeMs} ms"
                } else {
                    ""
                }
                val codec = if (snapshot.codec.isNotEmpty()) " · ${snapshot.codec}" else ""
                Text(
                    "${snapshot.fps} fps · ${snapshot.decodeMs} ms · " +
                        "%.1f Mbps · drop ${snapshot.dropped}%s%s".format(snapshot.bitrateMbps, e2e, codec),
                    color = Color.White
                )
                if (phoneWidth > 0 && videoWidth > 0) {
                    Text(
                        "手机 ${phoneWidth}×${phoneHeight} · Mac ${videoWidth}×${videoHeight}",
                        color = Color.White
                    )
                }
                Text(status, color = Color.White)
            }
        }
    }
}