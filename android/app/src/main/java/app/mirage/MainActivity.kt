package app.mirage

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.app.PendingIntent
import android.util.DisplayMetrics
import android.view.Surface
import android.view.WindowManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.mirage.input.InputController
import app.mirage.input.KeyboardBridge
import app.mirage.input.TouchFrame
import app.mirage.net.Hello
import app.mirage.net.MdnsDiscovery
import app.mirage.net.PairingPayload
import app.mirage.net.FakeUsbStreamConnection
import app.mirage.net.TlsStreamConnection
import app.mirage.net.TransportKind
import app.mirage.net.TransportMode
import app.mirage.net.TransportSelector
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import app.mirage.net.MirageClient
import app.mirage.net.SessionConfig
import app.mirage.net.StatsSnapshot
import app.mirage.net.StreamConnection
import app.mirage.net.StreamStats
import app.mirage.net.TcpStreamConnection
import app.mirage.net.UsbStreamConnection
import app.mirage.net.VideoFrame
import app.mirage.ui.AspectSurfaceView
import app.mirage.ui.VideoView
import app.mirage.video.VideoDecoder
import kotlinx.coroutines.delay
import java.security.SecureRandom

class MainActivity : ComponentActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var decoder: VideoDecoder? = null

    private var decoderSurface: Surface? = null

    @Volatile
    private var surface: Surface? = null

    @Volatile
    private var config: SessionConfig? = null

    @Volatile
    private var pendingKeyframe: VideoFrame? = null

    private var surfaceView: AspectSurfaceView? = null
    private var client: MirageClient? = null
    private val stats = StreamStats()

    private lateinit var usbManager: UsbManager
    private var pendingAccessory: UsbAccessory? = null
    private var usingUsb = false
    private var closeHandled = false

    private val usbPermissionAction = "app.mirage.USB_PERMISSION"
    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                usbPermissionAction -> {
                    val granted = intent.getBooleanExtra(
                        UsbManager.EXTRA_PERMISSION_GRANTED,
                        false
                    )
                    val accessory = if (Build.VERSION.SDK_INT >= 33) {
                        intent.getParcelableExtra(
                            UsbManager.EXTRA_ACCESSORY,
                            UsbAccessory::class.java
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        intent.getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
                    } ?: pendingAccessory
                    pendingAccessory = null
                    if (granted && accessory != null) {
                        connect(
                            lastHost ?: savedHost,
                            lastPort.takeIf { it > 0 } ?: savedPort,
                            isReconnect = true
                        )
                    } else {
                        connecting = false
                        status = "USB 权限被拒绝"
                    }
                }

                UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> {
                    scheduleTransportSwitch()
                }

                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    pendingAccessory = null
                    scheduleTransportSwitch()
                }
            }
        }
    }

    private val transportModeKey = "transportMode"

    private var transportMode by mutableStateOf(TransportMode.AUTO)
    private var currentKind: TransportKind? = null
    private var fakeUsbAttached = false
    private var clientGeneration = 0
    private var switchRunnable: Runnable? = null

    private val debugReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!BuildConfig.DEBUG) return
            when (intent.action) {
                "app.mirage.DEBUG_USB_ATTACHED" -> {
                    fakeUsbAttached = true
                    scheduleTransportSwitch()
                }
                "app.mirage.DEBUG_USB_DETACHED" -> {
                    fakeUsbAttached = false
                    scheduleTransportSwitch()
                }
            }
        }
    }

    private var savedHost = ""
    private var savedPort = 0
    private var savedFingerprintHex = ""
    private var lastHost: String? = null
    private var lastPort: Int = 0
    private var autoReconnectEnabled = false
    private var manualDisconnect = false
    private var reconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null
    private val maxReconnectAttempts = 10

    private var edgeTracking = false
    private var edgeStartX = 0f
    private var edgeLastX = 0f
    private val edgeSwipeThreshold by lazy { 40 * resources.displayMetrics.density }

    private var connected by mutableStateOf(false)
    private var connecting by mutableStateOf(false)
    private var controlsVisible by mutableStateOf(false)
    private var showStats by mutableStateOf(false)
    private var phoneWidth by mutableStateOf(0)
    private var phoneHeight by mutableStateOf(0)
    private var videoWidth by mutableStateOf(0)
    private var videoHeight by mutableStateOf(0)
    private var status by mutableStateOf("未连接")
    private var transportInfo by mutableStateOf("")
    private var showSettings by mutableStateOf(false)
    private var inputCaps by mutableStateOf(0)
    private var inputAllowed by mutableStateOf(false)
    private var inputUserEnabled by mutableStateOf(true)
    private var touchFrames by mutableStateOf(0)
    private var inputReason by mutableStateOf<String?>(null)
    private var keyboardVisible by mutableStateOf(false)
    private val inputSender = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val inputController = InputController(send = { frame -> inputSender.execute { client?.sendInput(frame) } })
    private var keyboardBridge: KeyboardBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        usbManager = getSystemService(UsbManager::class.java)
        ContextCompat.registerReceiver(
            this,
            usbReceiver,
            IntentFilter().apply {
                addAction(usbPermissionAction)
                addAction(UsbManager.ACTION_USB_ACCESSORY_ATTACHED)
                addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
        if (BuildConfig.DEBUG) {
            ContextCompat.registerReceiver(
                this,
                debugReceiver,
                IntentFilter().apply {
                    addAction("app.mirage.DEBUG_USB_ATTACHED")
                    addAction("app.mirage.DEBUG_USB_DETACHED")
                },
                ContextCompat.RECEIVER_EXPORTED
            )
        }

        val preferences = getSharedPreferences("mirage", Context.MODE_PRIVATE)
        savedHost = preferences.getString("host", "") ?: ""
        savedPort = preferences.getInt("port", 0)
        savedFingerprintHex = preferences.getString("fingerprint", "") ?: ""
        transportMode = preferences.getString(transportModeKey, null)
            ?.let { runCatching { TransportMode.valueOf(it) }.getOrNull() }
            ?: TransportMode.AUTO
        val metrics = screenMetrics()
        phoneWidth = metrics.widthPixels
        phoneHeight = metrics.heightPixels
        val configured = savedHost.isNotBlank() && savedPort > 0
        val hasAccessory = findMirageAccessory() != null
        if (!configured && !hasAccessory) {
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
                                transportInfo = transportInfo,
                                inputEnabled = connected && inputAllowed && inputUserEnabled && !controlsVisible,
                                inputReason = inputReason,
                                touchFrames = touchFrames,
                                onInputFrame = {
                                    touchFrames++
                                    inputController.onFrame(it)
                                },
                                onSurfaceReady = { view, newSurface ->
                                    surfaceView = view
                                    surface = newSurface
                                    maybeStartDecoder()
                                },
                                onSurfaceDestroyed = {
                                    decoder?.release()
                                    decoder = null
                                    decoderSurface = null
                                    surface = null
                                }
                            )
                        }
                    } else {
                        DisconnectedScreen(
                            status = status,
                            connecting = connecting,
                            connectEnabled = !connecting,
                            onConnect = {
                                if (savedHost.isNotBlank() && savedPort > 0) {
                                    connect(savedHost, savedPort)
                                } else {
                                    showSettings = true
                                }
                            },
                            onSettings = { showSettings = true }
                        )
                    }

                    if (connected && controlsVisible) {
                        Row(
                            modifier = Modifier.fillMaxSize(),
                            horizontalArrangement = Arrangement.End
                        ) {
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .fillMaxHeight()
                                    .background(Color.Black.copy(alpha = 0.25f))
                                    .clickable { controlsVisible = false }
                            )
                            Column(
                                modifier = Modifier
                                    .fillMaxHeight()
                                    .width(88.dp)
                                    .background(Color(0xEE2B2B30))
                                    .windowInsetsPadding(
                                        WindowInsets.safeDrawing.only(
                                            WindowInsetsSides.Top + WindowInsetsSides.End
                                        )
                                    )
                                    .padding(vertical = 12.dp),
                                horizontalAlignment = Alignment.CenterHorizontally,
                                verticalArrangement = Arrangement.spacedBy(10.dp)
                            ) {
                                IconButton(onClick = {
                                    controlsVisible = false
                                    showSettings = true
                                }) {
                                    Icon(
                                        Icons.Default.Settings,
                                        contentDescription = "设置",
                                        modifier = Modifier.size(24.dp)
                                    )
                                }
                                IconButton(onClick = {
                                    switchTransport(nextTransport(transportMode))
                                }) {
                                    Icon(
                                        Icons.Default.Refresh,
                                        contentDescription = "切换连接（${transportMode.name}）",
                                        modifier = Modifier.size(24.dp)
                                    )
                                }
                                if (inputCaps and 6 != 0) {
                                    IconButton(onClick = {
                                        keyboardBridge?.toggle()
                                    }) {
                                        Icon(
                                            Icons.Default.Edit,
                                            contentDescription = if (keyboardVisible) "收起键盘" else "键盘",
                                            modifier = Modifier.size(24.dp)
                                        )
                                    }
                                }
                                if (connected && inputCaps == 0) {
                                    Text("输入未开放", color = Color(0xFFFFB74D), fontSize = 12.sp)
                                }
                                if (inputCaps and 1 != 0) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text("输入", color = Color.White)
                                        Switch(
                                            checked = inputUserEnabled && inputAllowed,
                                            onCheckedChange = {
                                                inputUserEnabled = it
                                                keyboardBridge?.enabled = it && inputAllowed && inputCaps and 6 != 0
                                                if (!it) {
                                                    inputController.releaseAll()
                                                    keyboardBridge?.hide()
                                                }
                                            },
                                            modifier = Modifier
                                                .padding(start = 2.dp)
                                                .scale(0.7f)
                                        )
                                    }
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        Icons.Default.Info,
                                        contentDescription = "调试",
                                        modifier = Modifier.size(20.dp)
                                    )
                                    Switch(
                                        checked = showStats,
                                        onCheckedChange = { showStats = it },
                                        modifier = Modifier
                                            .padding(start = 2.dp)
                                            .scale(0.7f)
                                    )
                                }
                                IconButton(onClick = { disconnect() }) {
                                    Icon(
                                        Icons.Default.Close,
                                        contentDescription = "断开",
                                        modifier = Modifier.size(24.dp)
                                    )
                                }
                                Spacer(Modifier.weight(1f))
                                IconButton(onClick = { controlsVisible = false }) {
                                    Icon(
                                        Icons.Default.KeyboardArrowRight,
                                        contentDescription = "收起",
                                        modifier = Modifier.size(24.dp)
                                    )
                                }
                            }
                        }
                    } else if (connected) {
                        Box(
                            modifier = Modifier
                                .align(Alignment.CenterEnd)
                                .size(width = 18.dp, height = 56.dp)
                                .clip(RoundedCornerShape(topStart = 8.dp, bottomStart = 8.dp))
                                .background(Color.Black.copy(alpha = 0.35f))
                                .clickable { controlsVisible = true }
                        )
                    }
                }

                if (showSettings) {
                    SettingsDialog(
                        initialHost = savedHost.ifBlank { "127.0.0.1" },
                        initialPort = if (savedPort > 0) savedPort.toString() else "7778",
                        initialFingerprint = savedFingerprintHex,
                        initialTransport = transportMode,
                        onTransport = { switchTransport(it) },
                        onDismiss = { showSettings = false },
                        onSave = { host, port, fingerprintHex ->
                            savedHost = host
                            savedPort = port
                            savedFingerprintHex = fingerprintHex
                            preferences.edit()
                                .putString("host", host)
                                .putInt("port", port)
                                .putString("fingerprint", fingerprintHex)
                                .apply()
                            showSettings = false
                            connect(host, port)
                        }
                    )
                }
            }
        }

        keyboardBridge = KeyboardBridge(
            this,
            forward = { inputController.forward(it) },
            onVisible = { keyboardVisible = it }
        )

        if (configured || hasAccessory) {
            connect(savedHost, savedPort)
        }

        hideSystemBars()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            val accessory = intent.getAccessory()
            if (accessory != null) {
                pendingAccessory = accessory
                connect(
                    lastHost ?: savedHost,
                    lastPort.takeIf { it > 0 } ?: savedPort,
                    isReconnect = true
                )
            }
        }
    }

    override fun dispatchTouchEvent(event: android.view.MotionEvent): Boolean {
        when (event.actionMasked) {
            android.view.MotionEvent.ACTION_DOWN -> {
                edgeTracking = connected &&
                    event.x > resources.displayMetrics.widthPixels * 0.85f
                edgeStartX = event.x
                edgeLastX = event.x
            }
            android.view.MotionEvent.ACTION_MOVE -> {
                if (edgeTracking) edgeLastX = event.x
            }
            android.view.MotionEvent.ACTION_UP, android.view.MotionEvent.ACTION_CANCEL -> {
                if (edgeTracking && !controlsVisible &&
                    edgeStartX - edgeLastX > edgeSwipeThreshold
                ) {
                    controlsVisible = true
                }
                edgeTracking = false
            }
        }
        return super.dispatchTouchEvent(event)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemBars()
        }
    }

    override fun onResume() {
        super.onResume()
        switchTransportIfNeeded()
        keyboardBridge?.enabled = connected && inputAllowed && inputUserEnabled &&
            inputCaps and 6 != 0
    }

    override fun onPause() {
        keyboardBridge?.hide()
        inputController.releaseAll()
        super.onPause()
    }

    override fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        val bridge = keyboardBridge
        if (bridge != null && connected && inputAllowed && inputUserEnabled && bridge.dispatchKeyEvent(event)) {
            return true
        }
        return super.dispatchKeyEvent(event)
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
        try {
            unregisterReceiver(usbReceiver)
        } catch (_: Exception) {
        }
        if (BuildConfig.DEBUG) {
            try {
                unregisterReceiver(debugReceiver)
            } catch (_: Exception) {
            }
        }
        switchRunnable?.let { mainHandler.removeCallbacks(it) }
        keyboardBridge?.destroy()
        keyboardBridge = null
        disconnect()
        inputSender.shutdown()
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

        client?.close()
        client = null

        val accessory = findMirageAccessory()
        val hasAccessory = accessory != null || (BuildConfig.DEBUG && fakeUsbAttached)
        val choice = TransportSelector.select(
            transportMode,
            hasAccessory,
            host.takeIf { it.isNotBlank() },
            port
        )
        currentKind = choice?.kind

        when (choice?.kind) {
            null -> {
                connecting = false
                status = "请先设置 Mac 地址或扫码配对"
                showSettings = true
            }

            TransportKind.WAIT_USB -> {
                connecting = false
                status = "等待 USB 连接…（未检测到设备）"
            }

            TransportKind.USB -> {
                if (accessory != null) {
                    if (!usbManager.hasPermission(accessory)) {
                        pendingAccessory = accessory
                        status = "等待 USB 授权…"
                        requestUsbPermission(accessory)
                        return
                    }
                    status = if (isReconnect) "重连中…（USB）" else "连接中…（USB）"
                    startClient(
                        { UsbStreamConnection(usbManager, accessory) },
                        TransportKind.USB,
                        "USB"
                    )
                } else {
                    status = if (isReconnect) "重连中…（USB 模拟）" else "连接中…（USB 模拟）"
                    startClient({ FakeUsbStreamConnection() }, TransportKind.USB, "USB (模拟)")
                }
            }

            TransportKind.WIFI -> {
                val wifiHost = choice.host ?: host
                val wifiPort = choice.port
                if (isLoopbackHost(wifiHost)) {
                    status = if (isReconnect) "重连中…（TCP）" else "连接中…（TCP）"
                    startClient(
                        { TcpStreamConnection(wifiHost, wifiPort) },
                        TransportKind.WIFI,
                        "TCP $wifiHost:$wifiPort"
                    )
                } else {
                    val fingerprint = PairingPayload.decodeFingerprint(savedFingerprintHex)
                    if (fingerprint == null) {
                        connecting = false
                        status = "请先扫码配对以确认 Mac 指纹"
                        showSettings = true
                        return
                    }
                    status = if (isReconnect) "重连中…（第 $reconnectAttempts 次）" else "连接中…"
                    startClient(
                        { TlsStreamConnection(wifiHost, wifiPort, fingerprint) },
                        TransportKind.WIFI,
                        "Wi-Fi $wifiHost:$wifiPort"
                    )
                }
            }

            TransportKind.TCP -> {
                status = if (isReconnect) "重连中…（TCP）" else "连接中…（TCP）"
                startClient(
                    { TcpStreamConnection("127.0.0.1", 7777) },
                    TransportKind.TCP,
                    "TCP 127.0.0.1:7777"
                )
            }
        }
    }

    private fun switchTransport(mode: TransportMode) {
        if (mode == transportMode) return
        transportMode = mode
        getSharedPreferences("mirage", Context.MODE_PRIVATE).edit()
            .putString(transportModeKey, mode.name)
            .apply()
        if (mode == TransportMode.WIFI && (savedHost.isBlank() || savedPort <= 0)) {
            currentKind = null
            connecting = false
            status = "Wi-Fi 模式需要先设置地址或扫码配对"
            showSettings = true
            return
        }
        if (mode == TransportMode.TCP) {
            lastHost = "127.0.0.1"
            lastPort = 7777
        }
        reconnectTransport()
    }

    private fun scheduleTransportSwitch() {
        switchRunnable?.let { mainHandler.removeCallbacks(it) }
        val runnable = Runnable { switchTransportIfNeeded() }
        switchRunnable = runnable
        mainHandler.postDelayed(runnable, 500)
    }

    private fun switchTransportIfNeeded() {
        if (transportMode == TransportMode.WIFI || transportMode == TransportMode.TCP) return
        val hasAccessory = findMirageAccessory() != null || (BuildConfig.DEBUG && fakeUsbAttached)
        val desired = TransportSelector.select(
            transportMode,
            hasAccessory,
            savedHost,
            savedPort
        )?.kind ?: return
        if (desired != currentKind) {
            reconnectTransport()
        }
    }

    private fun reconnectTransport() {
        connecting = true
        clientGeneration++
        client?.close()
        client = null
        decoder?.release()
        decoder = null
        decoderSurface = null
        config = null
        pendingKeyframe = null
        connected = false
        closeHandled = false
        connect(lastHost ?: savedHost, lastPort.takeIf { it > 0 } ?: savedPort)
    }

    private fun startClient(open: () -> StreamConnection, kind: TransportKind, label: String) {
        usingUsb = kind == TransportKind.USB
        currentKind = kind
        closeHandled = false
        transportInfo = label
        val generation = ++clientGeneration
        val newClient = MirageClient(
            buildHello(),
            stats,
            object : MirageClient.Listener {
                override fun onConfig(newConfig: SessionConfig) {
                    mainHandler.post {
                        if (generation != clientGeneration) return@post
                        autoReconnectEnabled = true
                        reconnectAttempts = 0
                        connecting = false
                        config = newConfig
                        videoWidth = newConfig.width
                        videoHeight = newConfig.height
                        inputCaps = newConfig.inputCaps
                        inputAllowed = inputCaps and 1 != 0
                        inputReason = null
                        keyboardBridge?.enabled = inputAllowed && inputCaps and 6 != 0
                        setKeepScreenOn(true)
                        val transport = if (usingUsb) "USB " else ""
                        status = "已连接 $transport${newConfig.width}x${newConfig.height}@${newConfig.fps}"
                        connected = true
                        maybeStartDecoder()
                    }
                }

                override fun onVideo(frame: VideoFrame) {
                    if (generation != clientGeneration) return
                    val currentDecoder = decoder
                    if (currentDecoder != null) {
                        currentDecoder.submit(frame)
                    } else if (frame.header.flags and 1 != 0) {
                        pendingKeyframe = frame
                    }
                }

                override fun onClosed(reason: String) {
                    if (generation != clientGeneration) return
                    mainHandler.post { handleConnectionClosed(reason) }
                }

                override fun onUdpReady(ready: Boolean) {
                    mainHandler.post {
                        if (generation != clientGeneration) return@post
                        if (usingUsb) return@post
                        transportInfo = if (ready) "Wi-Fi UDP" else label
                    }
                }

                override fun onInputState(enabled: Boolean, reason: String?) {
                    mainHandler.post {
                        if (generation != clientGeneration) return@post
                        inputAllowed = enabled
                        inputReason = reason
                        keyboardBridge?.enabled = enabled && inputCaps and 6 != 0
                        if (!enabled) {
                            inputController.releaseAll()
                            keyboardBridge?.hide()
                        }
                    }
                }
            },
            open,
            serverHost = if (kind == TransportKind.WIFI && !isLoopbackHost(lastHost)) lastHost else null
        )
        client = newClient
        newClient.connect()
    }

    private fun findMirageAccessory(): UsbAccessory? {
        val accessories = usbManager.accessoryList ?: return null
        return accessories.firstOrNull {
            it.manufacturer == "Mirage" || it.model == "Mirage Display"
        } ?: accessories.singleOrNull()
    }

    private fun requestUsbPermission(accessory: UsbAccessory) {
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val intent = Intent(usbPermissionAction).setPackage(packageName)
        val pending = PendingIntent.getBroadcast(this, 0, intent, flags)
        usbManager.requestPermission(accessory, pending)
    }

    private fun Intent.getAccessory(): UsbAccessory? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }

    private fun handleConnectionClosed(reason: String) {
        if (closeHandled) return
        closeHandled = true
        inputController.releaseAll()
        keyboardBridge?.hide()
        keyboardBridge?.enabled = false
        inputAllowed = false
        inputCaps = 0
        client = null
        connected = false
        val displayReason = friendlyReason(reason)
        setKeepScreenOn(false)
        decoder?.release()
        decoder = null
        decoderSurface = null
        config = null
        pendingKeyframe = null
        videoWidth = 0
        videoHeight = 0
        controlsVisible = false

        if (manualDisconnect || !autoReconnectEnabled || isFinishing || isDestroyed) {
            if (!manualDisconnect) {
                status = displayReason
            }
            connecting = false
            connected = false
            return
        }

        if (usingUsb && findMirageAccessory() == null && transportMode == TransportMode.USB) {
            status = "USB 已断开，请重新插入 USB"
            connecting = true
            connected = false
            return
        }

        if (reconnectAttempts >= maxReconnectAttempts) {
            autoReconnectEnabled = false
            connecting = false
            connected = false
            status = "无法连接（$displayReason）"
            return
        }

        status = if (usingUsb) {
            "USB 连接已断开，自动重连中…"
        } else {
            "连接已断开，自动重连中…"
        }
        connecting = true
        scheduleReconnect()
    }

    private fun friendlyReason(reason: String): String {
        val lower = reason.lowercase()
        return when {
            "econnrefused" in lower || "failed to connect" in lower ->
                "无法连接 Mac（服务未启动或端口未转发）"
            "timeout" in lower || "timed out" in lower -> "连接 Mac 超时"
            else -> reason
        }
    }

    private fun scheduleReconnect() {
        val host = lastHost ?: return
        if ((host.isBlank() || lastPort <= 0) && findMirageAccessory() == null) {
            connecting = false
            connected = false
            status = "连接已断开"
            return
        }

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
        decoderSurface = null
        config = null
        pendingKeyframe = null
        surface = null
        surfaceView = null
        controlsVisible = false
        connecting = false
        connected = false
        status = "未连接"
    }

    private fun maybeStartDecoder() {
        val currentConfig = config ?: return
        val currentSurface = surface ?: return
        if (decoder != null && decoderSurface === currentSurface) return

        decoder?.release()
        decoder = null
        decoderSurface = null

        surfaceView?.applyVideoSize(currentConfig.width, currentConfig.height)
        var created: VideoDecoder? = null
        created = VideoDecoder(
            surface = currentSurface,
            config = currentConfig,
            stats = stats,
            onError = { message -> mainHandler.post { status = message } },
            onNeedKeyframe = { client?.requestKeyframe() },
            onStopped = {
                mainHandler.post {
                    if (decoder === created) {
                        decoder = null
                        decoderSurface = null
                    }
                }
            }
        )
        decoder = created
        decoderSurface = currentSurface
        created?.start()
        pendingKeyframe?.let {
            created?.submit(it)
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
private fun DisconnectedScreen(
    status: String,
    connecting: Boolean,
    connectEnabled: Boolean,
    onConnect: () -> Unit,
    onSettings: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .windowInsetsPadding(WindowInsets.safeDrawing)
            .padding(24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text("Mirage", style = MaterialTheme.typography.headlineMedium)
        Spacer(Modifier.height(16.dp))
        if (connecting) {
            CircularProgressIndicator(
                modifier = Modifier.size(36.dp),
                strokeWidth = 3.dp
            )
            Spacer(Modifier.height(16.dp))
        }
        Text(status)
        Spacer(Modifier.height(24.dp))
        Button(onClick = onConnect, enabled = connectEnabled) {
            Text("连接")
        }
        Spacer(Modifier.height(8.dp))
        TextButton(onClick = onSettings) {
            Text("设置")
        }
    }
}

@Composable
private fun SettingsDialog(
    initialHost: String,
    initialPort: String,
    initialFingerprint: String,
    initialTransport: TransportMode,
    onTransport: (TransportMode) -> Unit,
    onDismiss: () -> Unit,
    onSave: (String, Int, String) -> Unit
) {
    var host by remember { mutableStateOf(initialHost) }
    var port by remember { mutableStateOf(initialPort) }
    var fingerprintHex by remember { mutableStateOf(initialFingerprint) }
    var error by remember { mutableStateOf<String?>(null) }
    var discovering by remember { mutableStateOf(false) }
    var discoveryMessage by remember { mutableStateOf<String?>(null) }
    var pasteLink by remember { mutableStateOf("") }
    val context = LocalContext.current
    val discovery = remember { MdnsDiscovery(context) }

    fun applyPayload(payload: PairingPayload) {
        host = payload.host
        port = payload.port.toString()
        fingerprintHex = payload.fingerprintHex
        discoveryMessage = "已配对「${payload.name}」"
    }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        val contents = result.contents
        val payload = contents?.let(PairingPayload::parse)
        if (payload == null) {
            error = "二维码不是有效的 Mirage 配对码"
        } else {
            error = null
            applyPayload(payload)
        }
    }

    DisposableEffect(Unit) {
        onDispose { discovery.stop() }
    }

    AlertDialog(
        onDismissRequest = {
            discovery.stop()
            onDismiss()
        },
        title = { Text("连接设置") },
        text = {
            Column {
                Text("连接方式", style = MaterialTheme.typography.labelLarge)
                Row {
                    listOf(
                        TransportMode.AUTO to "自动",
                        TransportMode.USB to "USB",
                        TransportMode.WIFI to "Wi-Fi",
                        TransportMode.TCP to "TCP"
                    ).forEach { (mode, label) ->
                        TextButton(onClick = { onTransport(mode) }) {
                            Text(
                                (if (mode == initialTransport) "✓ " else "") + label,
                                style = MaterialTheme.typography.bodySmall
                            )
                        }
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Button(onClick = {
                        error = null
                        scanner.launch(
                            ScanOptions()
                                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                                .setPrompt("扫描 Mac 上的 Mirage 配对二维码")
                                .setBeepEnabled(false)
                                .setOrientationLocked(true)
                        )
                    }) {
                        Text("扫码配对")
                    }
                    Spacer(Modifier.width(8.dp))
                    TextButton(
                        onClick = {
                            discovering = true
                            discoveryMessage = "搜索局域网…"
                            discovery.start(
                                onFound = { foundHost, foundPort, attributes ->
                                    host = foundHost
                                    port = foundPort.toString()
                                    discovering = false
                                    discovery.stop()
                                    val advertised = attributes["fp"]
                                    if (!advertised.isNullOrBlank() && advertised == fingerprintHex) {
                                        discoveryMessage = "已发现已配对 Mac，正在连接…"
                                        onSave(foundHost, foundPort, fingerprintHex)
                                    } else {
                                        val name = attributes["name"] ?: foundHost
                                        discoveryMessage = "发现「$name」，需扫码确认指纹"
                                    }
                                },
                                onError = { message ->
                                    discovering = false
                                    discoveryMessage = message
                                }
                            )
                        },
                        enabled = !discovering
                    ) {
                        Text(if (discovering) "搜索中…" else "发现 Mac")
                    }
                    discoveryMessage?.let {
                        Spacer(Modifier.width(8.dp))
                        Text(it, style = MaterialTheme.typography.bodySmall)
                    }
                }
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
                    label = { Text("端口（TLS 为 7778）") },
                    singleLine = true
                )
                Spacer(Modifier.height(12.dp))
                OutlinedTextField(
                    value = pasteLink,
                    onValueChange = {
                        pasteLink = it
                        PairingPayload.parse(it)?.let { payload ->
                            error = null
                            applyPayload(payload)
                        }
                    },
                    label = { Text("配对链接（扫码失败时粘贴）") },
                    singleLine = true
                )
                if (fingerprintHex.isNotBlank()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "指纹 ${fingerprintHex.take(8)}…",
                        style = MaterialTheme.typography.bodySmall
                    )
                }
                error?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, color = MaterialTheme.colorScheme.error)
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val parsedPort = port.toIntOrNull()
                when {
                    host.isBlank() || parsedPort == null || parsedPort <= 0 ->
                        error = "地址或端口无效"
                    !isLoopbackHost(host) &&
                        PairingPayload.decodeFingerprint(fingerprintHex) == null ->
                        error = "Wi-Fi 连接需要配对指纹，请扫码或粘贴配对链接"
                    else -> {
                        discovery.stop()
                        onSave(host.trim(), parsedPort, fingerprintHex)
                    }
                }
            }) {
                Text("保存并连接")
            }
        },
        dismissButton = {
            TextButton(onClick = {
                discovery.stop()
                onDismiss()
            }) {
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
    transportInfo: String,
    inputEnabled: Boolean,
    inputReason: String?,
    touchFrames: Int,
    onInputFrame: (TouchFrame) -> Unit,
    onSurfaceReady: (AspectSurfaceView, Surface) -> Unit,
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
            onSurfaceDestroyed = onSurfaceDestroyed,
            inputEnabled = inputEnabled,
            onInputFrame = onInputFrame
        )
        inputReason?.let {
            Text(
                it,
                color = Color.White,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .background(Color.Black.copy(alpha = 0.5f))
                    .padding(8.dp)
            )
        }
        if (showStats) {
            Column(
                modifier = Modifier
                    .align(Alignment.BottomStart)
                    .background(Color.Black.copy(alpha = 0.5f))
                    .padding(12.dp)
            ) {
                val codec = if (snapshot.codec.isNotEmpty()) " · ${snapshot.codec}" else ""
                Text(
                    "${snapshot.fps} fps · %.1f Mbps · drop ${snapshot.dropped}%s"
                        .format(snapshot.bitrateMbps, codec),
                    color = Color.White
                )
                val e2e = if (snapshot.e2eMs >= 0) {
                    "${snapshot.e2eMs + snapshot.decodeMs}"
                } else {
                    "--"
                }
                val rtt = if (snapshot.rttMs >= 0) "${snapshot.rttMs}" else "--"
                Text(
                    "延迟 decode=${snapshot.decodeMs} ms · e2e=$e2e ms · rtt=$rtt ms",
                    color = Color.White
                )
                if (phoneWidth > 0 && videoWidth > 0) {
                    Text(
                        "手机 ${phoneWidth}×${phoneHeight} · Mac ${videoWidth}×${videoHeight}",
                        color = Color.White
                    )
                }
                if (transportInfo.isNotEmpty()) {
                    Text("连接 $transportInfo", color = Color.White)
                }
                Text(
                    "输入 ${if (inputEnabled) "开" else "关"} · 触摸 $touchFrames",
                    color = Color.White
                )
                Text(status, color = Color.White)
            }
        }
    }
}

private fun isLoopbackHost(host: String?): Boolean =
    host == "localhost" || host == "::1" || host?.startsWith("127.") == true

private fun nextTransport(mode: TransportMode): TransportMode = when (mode) {
    TransportMode.AUTO -> TransportMode.USB
    TransportMode.USB -> TransportMode.WIFI
    TransportMode.WIFI -> TransportMode.TCP
    TransportMode.TCP -> TransportMode.AUTO
}