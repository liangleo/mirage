package app.mirage.session

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Handler
import android.view.Surface
import androidx.activity.ComponentActivity
import app.mirage.BuildConfig
import app.mirage.input.InputController
import app.mirage.input.KeyboardBridge
import app.mirage.net.FakeUsbStreamConnection
import app.mirage.net.Hello
import app.mirage.net.MirageClient
import app.mirage.net.PairingPayload
import app.mirage.net.SessionConfig
import app.mirage.net.StreamConnection
import app.mirage.net.StreamStats
import app.mirage.net.TcpStreamConnection
import app.mirage.net.TlsStreamConnection
import app.mirage.net.TransportKind
import app.mirage.net.TransportMode
import app.mirage.net.UsbStreamConnection
import app.mirage.net.VideoFrame
import app.mirage.ui.AspectSurfaceView
import app.mirage.video.VideoDecoder
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.security.SecureRandom

class SessionController(
    private val activity: ComponentActivity,
    private val mainHandler: Handler,
    private val preferences: SharedPreferences,
    private val keepScreenOn: (Boolean) -> Unit
) {
    companion object {
        const val USB_PERMISSION_ACTION = "app.mirage.USB_PERMISSION"
    }

    private val uiState = MutableStateFlow(SessionUiState())
    val ui: StateFlow<SessionUiState> = uiState

    val stats = StreamStats()

    private val usbManager = activity.getSystemService(UsbManager::class.java)
    private var pendingAccessory: UsbAccessory? = null
    private var usingUsb = false
    private var closeHandled = false

    private var client: MirageClient? = null
    private var clientGeneration = 0
    private var decoder: VideoDecoder? = null
    private var decoderSurface: Surface? = null

    @Volatile
    private var surface: Surface? = null

    private var surfaceView: AspectSurfaceView? = null
    private var config: SessionConfig? = null
    private var pendingKeyframe: VideoFrame? = null

    private var savedHost = ""
    private var savedPort = 0
    private var savedFingerprintHex = ""
    private var lastHost: String? = null
    private var lastPort = 0
    private var autoReconnectEnabled = false
    private var manualDisconnect = false
    private var reconnectAttempts = 0
    private var reconnectRunnable: Runnable? = null
    private var switchRunnable: Runnable? = null
    private var fakeUsbAttached = false
    private var currentKind: TransportKind? = null
    private var autoStage = 0
    private var usbSwitch = UsbSwitchState()
    private var usbCooldownUntilMs = 0L
    private var usbSwitchInFlight = false
    private var pendingUsbAccessory: UsbAccessory? = null
    private var usbPermissionRequested = false
    private var usbPollRunnable: Runnable? = null
    private var lastScreen: ScreenSnapshot? = null
    private var reconnectDeadlineMs = -1L
    private var overlayRunnable: Runnable? = null
    private var machine = MachineState()
    private var resizeKind: TransportKind? = null
    private var userInitiated = false

    private val inputSender = java.util.concurrent.Executors.newSingleThreadExecutor()
    private val inputController = InputController(send = { frame ->
        inputSender.execute { client?.sendInput(frame) }
    })
    private var keyboardBridge: KeyboardBridge? = null

    init {
        val stored = SettingsCodec.decode(preferences.all)
        savedHost = stored.host
        savedPort = stored.port
        savedFingerprintHex = stored.fingerprint
        uiState.value = uiState.value.copy(
            transportMode = stored.transportMode,
            savedHost = savedHost,
            savedPort = savedPort,
            savedFingerprint = savedFingerprintHex,
            debugOn = stored.debugOn,
            inputOn = stored.inputOn,
            phoneWidth = displayMetrics().widthPixels,
            phoneHeight = displayMetrics().heightPixels
        )
        lastScreen = currentScreen()
    }

    fun updateScreen() {
        val next = currentScreen()
        val previous = lastScreen
        update { it.copy(phoneWidth = next.width, phoneHeight = next.height) }
        if (!ScreenChange.shouldResendHello(previous, next)) return
        lastScreen = next
        if (!uiState.value.connected) return
        client?.updateHello(buildHello())
        reconnectForResize()
    }

    private fun reconnectForResize() {
        resizeKind = currentKind
        machineEvent(SessionEvent.TransportChanged)
        autoReconnectEnabled = true
        manualDisconnect = false
        clientGeneration++
        client?.close()
        client = null
        decoder?.release()
        decoder = null
        decoderSurface = null
        config = null
        pendingKeyframe = null
        closeHandled = false
        if (reconnectDeadlineMs < 0) {
            reconnectDeadlineMs = System.currentTimeMillis() + ReconnectPolicy.OUTER_WINDOW_MS
        }
        val remain = ((reconnectDeadlineMs - System.currentTimeMillis()) / 1000).toInt()
        update {
            it.copy(
                inStream = true,
                connected = false,
                connecting = true,
                status = "正在按新方向重连…",
                overlay = ReconnectOverlay("正在按新方向重连…", remain.coerceAtLeast(0))
            )
        }
        startOverlayTicker()
        mainHandler.postDelayed({
            if (activity.isFinishing || activity.isDestroyed) return@postDelayed
            connect(lastHost ?: savedHost, lastPort.takeIf { it > 0 } ?: savedPort, isReconnect = true)
        }, 800)
    }

    private fun currentScreen(): ScreenSnapshot {
        val size = screenSize()
        val rotation = when (currentDisplay()?.rotation ?: Surface.ROTATION_0) {
            Surface.ROTATION_90 -> 1
            Surface.ROTATION_180 -> 2
            Surface.ROTATION_270 -> 3
            else -> 0
        }
        return ScreenSnapshot(size.x, size.y, rotation)
    }

    private fun screenSize(): android.graphics.Point {
        val point = android.graphics.Point()
        currentDisplay()?.getRealSize(point)
        if (point.x <= 0 || point.y <= 0) {
            val metrics = displayMetrics()
            point.set(metrics.widthPixels, metrics.heightPixels)
        }
        return point
    }

    fun attachKeyboard() {
        if (keyboardBridge != null) return
        keyboardBridge = KeyboardBridge(
            activity,
            forward = { inputController.forward(it) },
            onVisible = { visible -> update { it.copy(keyboardVisible = visible) } }
        )
        keyboardBridge?.enabled = keyboardEnabled()
    }

    fun start() {
        // 冷启动不自动连接：关闭 App 视为主动断开，重开只回到连接页等用户操作。
        startUsbPolling()
        update { it.copy(status = "未连接") }
    }

    fun onResume() {
        switchTransportIfNeeded()
        keyboardBridge?.enabled = keyboardEnabled()
    }

    fun onPause() {
        keyboardBridge?.hide()
        inputController.releaseAll()
    }

    fun close() {
        switchRunnable?.let { mainHandler.removeCallbacks(it) }
        switchRunnable = null
        usbPollRunnable?.let { mainHandler.removeCallbacks(it) }
        usbPollRunnable = null
        overlayRunnable?.let { mainHandler.removeCallbacks(it) }
        overlayRunnable = null
        keyboardBridge?.destroy()
        keyboardBridge = null
        disconnect()
        inputSender.shutdown()
    }

    fun onAccessoryPermission(granted: Boolean, accessory: UsbAccessory?) {
        usbPermissionRequested = false
        android.util.Log.i("MirageUsb", "permission granted=$granted accessory=${accessory != null}")
        if (!userInitiated) {
            pendingAccessory = null
            pendingUsbAccessory = null
            return
        }
        val target = accessory ?: pendingAccessory ?: pendingUsbAccessory
        pendingAccessory = null
        pendingUsbAccessory = null
        if (granted && target != null) {
            if (uiState.value.connected && currentKind != TransportKind.USB) {
                performUsbSwitch()
            } else {
                connect(
                    lastHost ?: savedHost,
                    lastPort.takeIf { it > 0 } ?: savedPort,
                    isReconnect = true
                )
            }
        } else {
            usbCooldownUntilMs = System.currentTimeMillis() + 15_000
            update { it.copy(connecting = false, status = "USB 权限被拒绝") }
        }
    }

    fun onAccessoryAttached(accessory: UsbAccessory?) {
        if (!userInitiated) return
        if (accessory != null) {
            pendingAccessory = accessory
            connect(
                lastHost ?: savedHost,
                lastPort.takeIf { it > 0 } ?: savedPort,
                isReconnect = true
            )
        } else if (uiState.value.transportMode == TransportMode.AUTO && uiState.value.connected) {
            switchToUsb()
        } else {
            scheduleTransportSwitch()
        }
    }

    fun onAccessoryDetached() {
        pendingAccessory = null
        usbSwitch = UsbSwitchPolicy.onDetach(usbSwitch)
        usbSwitchInFlight = false
        usbPermissionRequested = false
        pendingUsbAccessory = null
        usbCooldownUntilMs = 0
        resetAutoStageForWifi()
        scheduleTransportSwitch()
    }

    private fun resetAutoStageForWifi() {
        if (uiState.value.transportMode != TransportMode.AUTO) return
        autoStage = 0
        if (savedHost.isNotBlank() && savedPort > 0) {
            lastHost = savedHost
            lastPort = savedPort
        }
    }

    fun onFakeAccessory(attached: Boolean) {
        fakeUsbAttached = attached
        scheduleTransportSwitch()
    }

    fun onSurfaceReady(view: AspectSurfaceView, newSurface: Surface) {
        surfaceView = view
        surface = newSurface
        maybeStartDecoder()
    }

    fun onSurfaceDestroyed() {
        decoder?.release()
        decoder = null
        decoderSurface = null
        surface = null
    }

    fun connect(host: String = savedHost, port: Int = savedPort, isReconnect: Boolean = false) {
        lastHost = host
        lastPort = port
        if (!isReconnect) {
            machineEvent(SessionEvent.Connect)
            autoReconnectEnabled = true
            manualDisconnect = false
            reconnectAttempts = 0
            autoStage = 0
        } else {
            machineEvent(SessionEvent.Retry)
        }
        update { it.copy(connecting = true) }

        client?.close()
        client = null

        val accessory = findMirageAccessory()
        val hasAccessory = accessory != null || (BuildConfig.DEBUG && fakeUsbAttached)
        val forced = resizeKind
        resizeKind = null
        fun planned(plan: TransportPlan?): app.mirage.net.TransportChoice? =
            plan?.let { app.mirage.net.TransportChoice(it.kind, it.host, it.port) }
        val choice: app.mirage.net.TransportChoice? = when (forced) {
            TransportKind.WIFI -> if (host.isNotBlank() && port > 0) {
                app.mirage.net.TransportChoice(TransportKind.WIFI, host, port)
            } else {
                planned(AutoPlan.select(uiState.value.transportMode, autoStage, hasAccessory, host, port))
            }
            TransportKind.TCP -> app.mirage.net.TransportChoice(TransportKind.TCP, "127.0.0.1", 7777)
            TransportKind.USB -> if (accessory != null) {
                app.mirage.net.TransportChoice(TransportKind.USB)
            } else {
                planned(AutoPlan.select(uiState.value.transportMode, autoStage, hasAccessory, host, port))
            }
            else -> planned(AutoPlan.select(uiState.value.transportMode, autoStage, hasAccessory, host, port))
        }
        currentKind = choice?.kind
        choice?.kind?.let { machineEvent(SessionEvent.Select(it)) }
        if (choice?.kind == TransportKind.TCP) {
            lastHost = choice.host ?: "127.0.0.1"
            lastPort = choice.port
        }

        when (choice?.kind) {
            null -> {
                update {
                    it.copy(
                        connecting = false,
                        status = "请先设置 Mac 地址或扫码配对"
                    )
                }
            }

            TransportKind.WAIT_USB -> update {
                it.copy(connecting = false, status = "等待 USB 连接…（未检测到设备）")
            }

            TransportKind.USB -> {
                if (accessory != null) {
                    if (!usbManager.hasPermission(accessory)) {
                        pendingAccessory = accessory
                        update { it.copy(status = "等待 USB 授权…") }
                        requestUsbPermission(accessory)
                        return
                    }
                    update {
                        it.copy(
                            status = if (isReconnect) "重连中…（USB）" else "连接中…（USB）"
                        )
                    }
                    startClient(
                        { UsbStreamConnection(usbManager, accessory) },
                        TransportKind.USB,
                        "USB"
                    )
                } else {
                    update {
                        it.copy(
                            status = if (isReconnect) "重连中…（USB 模拟）" else "连接中…（USB 模拟）"
                        )
                    }
                    startClient({ FakeUsbStreamConnection() }, TransportKind.USB, "USB (模拟)")
                }
            }

            TransportKind.WIFI -> {
                val wifiHost = choice.host ?: host
                val wifiPort = choice.port
                if (isLoopbackHost(wifiHost)) {
                    update {
                        it.copy(status = if (isReconnect) "重连中…（TCP）" else "连接中…（TCP）")
                    }
                    startClient(
                        { TcpStreamConnection(wifiHost, wifiPort) },
                        TransportKind.WIFI,
                        "TCP $wifiHost:$wifiPort"
                    )
                } else {
                    val fingerprint = PairingPayload.decodeFingerprint(savedFingerprintHex)
                    if (fingerprint == null) {
                        update {
                            it.copy(
                                connecting = false,
                                status = "请先扫码配对以确认 Mac 指纹"
                            )
                        }
                        return
                    }
                    update {
                        it.copy(
                            status = if (isReconnect) "重连中…（第 $reconnectAttempts 次）" else "连接中…"
                        )
                    }
                    startClient(
                        { TlsStreamConnection(wifiHost, wifiPort, fingerprint) },
                        TransportKind.WIFI,
                        "Wi-Fi $wifiHost:$wifiPort"
                    )
                }
            }

            TransportKind.TCP -> {
                update {
                    it.copy(status = if (isReconnect) "重连中…（TCP）" else "连接中…（TCP）")
                }
                startClient(
                    { TcpStreamConnection("127.0.0.1", 7777) },
                    TransportKind.TCP,
                    "TCP 127.0.0.1:7777"
                )
            }
        }
    }

    private fun machineEvent(event: SessionEvent) {
        machine = reduce(machine, event)
    }

    fun disconnect() {
        machineEvent(SessionEvent.Disconnect)
        userInitiated = false
        manualDisconnect = true
        autoReconnectEnabled = false
        keepScreenOn(false)
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
        reconnectDeadlineMs = -1
        overlayRunnable?.let { mainHandler.removeCallbacks(it) }
        overlayRunnable = null
        update {
            it.copy(
                inStream = false,
                connecting = false,
                connected = false,
                overlay = null,
                status = "未连接",
                inputCaps = 0,
                inputAllowed = false,
                inputReason = null,
                videoWidth = 0,
                videoHeight = 0
            )
        }
    }

    fun switchTransport(mode: TransportMode) {
        if (mode == uiState.value.transportMode) return
        update { it.copy(transportMode = mode) }
        preferences.edit().putString("transportMode", mode.name).apply()
        // 连接页上只切换选择；真正建立连接由「连接」按钮触发。串流中切换才立即重连。
        if (!uiState.value.inStream) return
        if (mode == TransportMode.TCP) {
            lastHost = "127.0.0.1"
            lastPort = 7777
        } else if (mode == TransportMode.WIFI && savedHost.isNotBlank() && savedPort > 0) {
            lastHost = savedHost
            lastPort = savedPort
        }
        reconnectTransport()
    }

    fun connectTo(host: String, port: Int, fingerprintHex: String) {
        userInitiated = true
        savedHost = host
        savedPort = port
        savedFingerprintHex = fingerprintHex
        update {
            it.copy(
                savedHost = host,
                savedPort = port,
                savedFingerprint = fingerprintHex
            )
        }
        connect(host, port)
    }

    fun setDebugOn(enabled: Boolean) {
        update { it.copy(debugOn = enabled) }
        preferences.edit().putBoolean("debugOn", enabled).apply()
    }

    fun setInputOn(enabled: Boolean) {
        update { it.copy(inputOn = enabled) }
        preferences.edit().putBoolean("inputOn", enabled).apply()
        keyboardBridge?.enabled = keyboardEnabled()
        if (!enabled) {
            inputController.releaseAll()
        }
    }

    fun toggleKeyboard() {
        keyboardBridge?.toggle()
    }

    fun keyboardVisible(): Boolean = uiState.value.keyboardVisible

    fun inputFrame(frame: app.mirage.input.TouchFrame) {
        inputController.onFrame(frame)
    }

    fun dispatchKeyEvent(event: android.view.KeyEvent): Boolean {
        val bridge = keyboardBridge ?: return false
        if (!uiState.value.connected || !uiState.value.inputAllowed) {
            return false
        }
        return bridge.dispatchKeyEvent(event)
    }

    fun requestKeyframe() {
        client?.requestKeyframe()
    }

    private fun keyboardEnabled(): Boolean {
        val state = uiState.value
        return state.connected && state.inputAllowed && state.inputCaps and 6 != 0
    }

    private fun persistWifiPairing() {
        if (!SettingsCodec.shouldPersistPairing(currentKind == TransportKind.WIFI, true)) return
        val host = lastHost ?: return
        if (host.isBlank() || isLoopbackHost(host)) return
        savedHost = host
        savedPort = lastPort
        preferences.edit()
            .putString("host", host)
            .putInt("port", lastPort)
            .putString("fingerprint", savedFingerprintHex)
            .apply()
        update {
            it.copy(
                savedHost = host,
                savedPort = lastPort,
                savedFingerprint = savedFingerprintHex
            )
        }
    }

    private fun startClient(open: () -> StreamConnection, kind: TransportKind, label: String) {
        usingUsb = kind == TransportKind.USB
        currentKind = kind
        closeHandled = false
        val transportName = when (kind) {
            TransportKind.USB -> "USB"
            TransportKind.WIFI -> "Wi-Fi"
            TransportKind.TCP -> "TCP"
            TransportKind.WAIT_USB -> "USB"
        }
        update { it.copy(transportInfo = label, transportName = transportName) }
        val generation = ++clientGeneration
        val newClient = MirageClient(
            buildHello(),
            stats,
            object : MirageClient.Listener {
                override fun onConfig(config: SessionConfig) {
                    mainHandler.post {
                        if (generation != clientGeneration) return@post
                        machineEvent(SessionEvent.Config(config))
                        autoReconnectEnabled = true
                        reconnectAttempts = 0
                        autoStage = 0
                        if (usingUsb) {
                            usbSwitch = UsbSwitchState()
                            usbSwitchInFlight = false
                            usbCooldownUntilMs = 0
                        }
                        persistWifiPairing()
                        this@SessionController.config = config
                        if (lastScreen == null) lastScreen = currentScreen()
                        val previous = uiState.value.videoWidth to uiState.value.videoHeight
                        if (previous.first > 0 && previous.second > 0 &&
                            (previous.first != config.width || previous.second != config.height)
                        ) {
                            decoder?.release()
                            decoder = null
                            decoderSurface = null
                            pendingKeyframe = null
                        }
                        val transport = if (usingUsb) "USB " else ""
                        reconnectDeadlineMs = -1
                        overlayRunnable?.let { mainHandler.removeCallbacks(it) }
                        overlayRunnable = null
                        update {
                            it.copy(
                                inStream = true,
                                overlay = null,
                                connecting = false,
                                connected = true,
                                videoWidth = config.width,
                                videoHeight = config.height,
                                inputCaps = config.inputCaps,
                                inputAllowed = config.inputCaps and 1 != 0,
                                inputReason = null,
                                status = "已连接 $transport${config.width}x${config.height}@${config.fps}"
                            )
                        }
                        keyboardBridge?.enabled = keyboardEnabled()
                        keepScreenOn(true)
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
                        update {
                            it.copy(
                                transportInfo = if (ready) "Wi-Fi UDP" else label,
                                transportName = if (ready) "Wi-Fi UDP" else "Wi-Fi"
                            )
                        }
                    }
                }

                override fun onInputState(enabled: Boolean, reason: String?) {
                    mainHandler.post {
                        if (generation != clientGeneration) return@post
                        update { it.copy(inputAllowed = enabled, inputReason = reason) }
                        keyboardBridge?.enabled = keyboardEnabled()
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

    private fun handleConnectionClosed(reason: String) {
        if (closeHandled) return
        closeHandled = true
        android.util.Log.i("MirageUsb", "closed reason=$reason usingUsb=$usingUsb inflight=$usbSwitchInFlight")
        if (usingUsb && !manualDisconnect) {
            usbCooldownUntilMs = System.currentTimeMillis() + 10_000
        }
        machineEvent(SessionEvent.Closed(reason))
        reconnectAttempts = machine.attempts
        inputController.releaseAll()
        keyboardBridge?.hide()
        keyboardBridge?.enabled = false
        client = null
        keepScreenOn(false)
        decoder?.release()
        decoder = null
        decoderSurface = null
        config = null
        pendingKeyframe = null
        update {
            it.copy(
                connected = false,
                inputAllowed = false,
                inputCaps = 0,
                inputReason = null,
                videoWidth = 0,
                videoHeight = 0
            )
        }

        val displayReason = friendlyReason(reason)
        val wasStreaming = uiState.value.inStream
        if (manualDisconnect || !autoReconnectEnabled || activity.isFinishing || activity.isDestroyed) {
            update {
                it.copy(
                    inStream = false,
                    overlay = null,
                    connecting = false,
                    connected = false,
                    status = if (manualDisconnect) it.status else displayReason
                )
            }
            return
        }

        if (!wasStreaming) {
            // 初次连接失败（例如服务未开/TCP 未转发）：回连接页，不占用 5 分钟重连窗口。
            autoReconnectEnabled = false
            reconnectDeadlineMs = -1
            reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
            reconnectRunnable = null
            update {
                it.copy(
                    inStream = false,
                    connected = false,
                    connecting = false,
                    overlay = null,
                    status = displayReason
                )
            }
            return
        }

        if (reconnectDeadlineMs < 0) {
            reconnectDeadlineMs = System.currentTimeMillis() + ReconnectPolicy.OUTER_WINDOW_MS
        }
        if (uiState.value.transportMode == TransportMode.AUTO) {
            if (usingUsb) {
                // USB 掉线（含立刻插回）先回 Wi-Fi，随后由 AUTO 轮询再切回 USB。
                autoStage = if (savedHost.isNotBlank() && savedPort > 0) 1 else 0
                if (savedHost.isNotBlank() && savedPort > 0) {
                    lastHost = savedHost
                    lastPort = savedPort
                }
            } else {
                autoStage = AutoPlan.nextStage(autoStage)
            }
        }

        val message = when {
            usingUsb && findMirageAccessory() == null &&
                uiState.value.transportMode == TransportMode.USB ->
                "USB 已断开，等待重新插入…"
            usingUsb -> "USB 连接已断开，正在重连…"
            else -> if (uiState.value.transportInfo.startsWith("Wi-Fi")) {
                "Wi-Fi 已断开，正在重连…"
            } else {
                "连接中断，正在重连…"
            }
        }
        val remain = ((reconnectDeadlineMs - System.currentTimeMillis()) / 1000).toInt()
        update {
            it.copy(
                inStream = true,
                connecting = true,
                status = message,
                overlay = ReconnectOverlay(message, remain.coerceAtLeast(0))
            )
        }
        startOverlayTicker()

        if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS &&
            System.currentTimeMillis() >= reconnectDeadlineMs
        ) {
            giveUpReconnect()
            return
        }
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        val host = lastHost ?: return
        if ((host.isBlank() || lastPort <= 0) && findMirageAccessory() == null) {
            if (uiState.value.transportMode == TransportMode.USB) return
            giveUpReconnect()
            return
        }

        reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        reconnectAttempts++
        val delayMs = if (reconnectAttempts <= ReconnectPolicy.MAX_INNER_ATTEMPTS) {
            ReconnectPolicy.innerBackoffMs(reconnectAttempts)
        } else {
            ReconnectPolicy.OUTER_RETRY_MS
        }

        val runnable = Runnable {
            if (activity.isFinishing || activity.isDestroyed || !autoReconnectEnabled || manualDisconnect) {
                return@Runnable
            }
            if (reconnectAttempts > ReconnectPolicy.MAX_INNER_ATTEMPTS) {
                resetAutoStageForWifi()
            }
            connect(lastHost ?: savedHost, lastPort.takeIf { it > 0 } ?: savedPort, isReconnect = true)
        }
        reconnectRunnable = runnable
        mainHandler.postDelayed(runnable, delayMs)
    }

    private fun scheduleTransportSwitch() {
        switchRunnable?.let { mainHandler.removeCallbacks(it) }
        val runnable = Runnable { switchTransportIfNeeded() }
        switchRunnable = runnable
        mainHandler.postDelayed(runnable, 500)
    }

    private fun startOverlayTicker() {
        if (overlayRunnable != null) return
        val runnable = object : Runnable {
            override fun run() {
                if (reconnectDeadlineMs < 0) {
                    overlayRunnable = null
                    return
                }
                val remain = ((reconnectDeadlineMs - System.currentTimeMillis()) / 1000).toInt()
                if (remain <= 0) {
                    overlayRunnable = null
                    giveUpReconnect()
                    return
                }
                update {
                    it.copy(overlay = it.overlay?.copy(remainSec = remain))
                }
                mainHandler.postDelayed(this, 500)
            }
        }
        overlayRunnable = runnable
        mainHandler.postDelayed(runnable, 500)
    }

    private fun giveUpReconnect() {
        machineEvent(SessionEvent.PermanentError("连接已断开"))
        reconnectDeadlineMs = -1
        autoReconnectEnabled = false
        reconnectRunnable?.let { mainHandler.removeCallbacks(it) }
        reconnectRunnable = null
        update {
            it.copy(
                inStream = false,
                connected = false,
                connecting = false,
                overlay = null,
                status = "连接已断开"
            )
        }
    }

    private fun switchTransportIfNeeded() {
        if (!userInitiated) return
        val mode = uiState.value.transportMode
        if (mode == TransportMode.WIFI || mode == TransportMode.TCP) return
        val hasAccessory = findMirageAccessory() != null || (BuildConfig.DEBUG && fakeUsbAttached)
        if (!hasAccessory && savedHost.isBlank() && lastHost == null) return
        val desired = AutoPlan.select(mode, 0, hasAccessory, savedHost, savedPort)?.kind ?: return
        if (desired != currentKind) reconnectTransport()
    }

    private fun switchToUsb() {
        if (currentKind == TransportKind.USB || usbSwitchInFlight) return
        val accessory = findMirageAccessory()
        android.util.Log.i("MirageUsb", "switchToUsb accessory=${accessory != null} permission=${accessory?.let { usbManager.hasPermission(it) }}")
        if (accessory == null) {
            client?.requestUsb()
            return
        }
        if (!usbManager.hasPermission(accessory)) {
            // 保持 Wi-Fi 串流，先请求授权；授权回调里再切 USB。
            if (!usbPermissionRequested) {
                usbPermissionRequested = true
                pendingUsbAccessory = accessory
                update { it.copy(status = "请在系统弹窗中允许 USB") }
                requestUsbPermission(accessory)
            }
            return
        }
        usbSwitch = UsbSwitchPolicy.onFailure(usbSwitch)
        if (usbSwitch.disabled) {
            usbCooldownUntilMs = System.currentTimeMillis() + 15_000
            return
        }
        performUsbSwitch()
    }

    private var usbSwitchToken = 0

    private fun performUsbSwitch() {
        if (currentKind == TransportKind.USB || usbSwitchInFlight) return
        usbSwitchInFlight = true
        val token = ++usbSwitchToken
        update { it.copy(connected = false, connecting = true, status = "已插回 USB，正在切换…") }
        // Wi-Fi 在线时 Mac 端 AOA 桥是暂停的；先请求恢复，否则关掉 Wi-Fi 后要等 30 秒。
        client?.requestUsb()
        mainHandler.postDelayed({
            if (activity.isFinishing || activity.isDestroyed || token != usbSwitchToken) return@postDelayed
            clientGeneration++
            client?.close()
            client = null
            decoder?.release()
            decoder = null
            decoderSurface = null
            config = null
            pendingKeyframe = null
            closeHandled = false
            awaitUsbAccessory(token, 0)
        }, 400)
    }

    private fun awaitUsbAccessory(token: Int, attempt: Int) {
        if (activity.isFinishing || activity.isDestroyed || token != usbSwitchToken) return
        val accessory = findMirageAccessory()
        if (accessory != null || (BuildConfig.DEBUG && fakeUsbAttached)) {
            android.util.Log.i("MirageUsb", "awaitUsbAccessory hit attempt=$attempt")
            connect(lastHost ?: savedHost, lastPort.takeIf { it > 0 } ?: savedPort, isReconnect = true)
            return
        }
        if (attempt >= 33) {
            android.util.Log.i("MirageUsb", "awaitUsbAccessory timeout, fallback wifi")
            usbSwitchInFlight = false
            usbCooldownUntilMs = System.currentTimeMillis() + 10_000
            usbSwitch = UsbSwitchPolicy.onFailure(usbSwitch)
            if (savedHost.isNotBlank() && savedPort > 0) {
                connect(savedHost, savedPort, isReconnect = true)
            }
            return
        }
        mainHandler.postDelayed({ awaitUsbAccessory(token, attempt + 1) }, 300)
    }

    private fun startUsbPolling() {
        if (usbPollRunnable != null) return
        val runnable = object : Runnable {
            override fun run() {
                if (activity.isFinishing || activity.isDestroyed) return
                val state = uiState.value
                val kind = currentKind
                if (kind != null && AutoPlan.shouldPollUsb(state.transportMode, state.connected, kind)) {
                    val now = System.currentTimeMillis()
                    if (usbSwitch.disabled && now >= usbCooldownUntilMs) {
                        usbSwitch = UsbSwitchState()
                    }
                    val accessory = findMirageAccessory()
                    val wantRequest = AutoPlan.shouldSendUsbRequest(state.transportMode, state.connected, kind)
                    val cooling = now < usbCooldownUntilMs
                    if (wantRequest) client?.requestUsb()
                    if (accessory != null && !usbSwitchInFlight && !cooling) {
                        switchToUsb()
                    }
                }
                mainHandler.postDelayed(this, 3_000)
            }
        }
        usbPollRunnable = runnable
        mainHandler.postDelayed(runnable, 3_000)
    }

    private fun reconnectTransport() {
        update { it.copy(connecting = true) }
        clientGeneration++
        client?.close()
        client = null
        decoder?.release()
        decoder = null
        decoderSurface = null
        config = null
        pendingKeyframe = null
        closeHandled = false
        update { it.copy(connected = false) }
        connect(lastHost ?: savedHost, lastPort.takeIf { it > 0 } ?: savedPort)
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
            onError = { message -> mainHandler.post { update { it.copy(status = message) } } },
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
        val metrics = displayMetrics()
        val size = screenSize()
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
            screenWidth = size.x,
            screenHeight = size.y,
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
            activity.display ?: activity.windowManager.defaultDisplay
        } else {
            activity.windowManager.defaultDisplay
        }

    private fun displayMetrics(): android.util.DisplayMetrics {
        val metrics = android.util.DisplayMetrics()
        val current = currentDisplay()
        if (current != null) {
            current.getRealMetrics(metrics)
        } else {
            @Suppress("DEPRECATION")
            metrics.setTo(activity.resources.displayMetrics)
        }
        return metrics
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
        val intent = Intent(USB_PERMISSION_ACTION).setPackage(activity.packageName)
        val pending = PendingIntent.getBroadcast(activity, 0, intent, flags)
        usbManager.requestPermission(accessory, pending)
    }

    private fun deviceID(): ByteArray {
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

    private fun friendlyReason(reason: String): String {
        val lower = reason.lowercase()
        return when {
            "econnrefused" in lower || "failed to connect" in lower ->
                "无法连接 Mac（服务未启动或端口未转发）"
            "timeout" in lower || "timed out" in lower -> "连接 Mac 超时"
            else -> reason
        }
    }

    private fun update(block: (SessionUiState) -> SessionUiState) {
        synchronized(uiState) {
            uiState.value = block(uiState.value)
        }
    }

    private fun isLoopbackHost(host: String?): Boolean =
        host == "localhost" || host == "::1" || host?.startsWith("127.") == true

    private val MAX_RECONNECT_ATTEMPTS = 10
}