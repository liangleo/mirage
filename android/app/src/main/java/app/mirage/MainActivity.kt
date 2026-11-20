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
import android.view.WindowManager
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import app.mirage.session.DockIntent
import app.mirage.session.DockState
import app.mirage.session.apply
import app.mirage.session.SessionController
import app.mirage.ui.ConnectScreen
import app.mirage.ui.StreamScreen
import app.mirage.ui.Toasts
import app.mirage.ui.MirageStrings
import kotlinx.coroutines.delay

class MainActivity : ComponentActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private lateinit var controller: SessionController

    private val backCallback = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() {
            // 播放页只允许通过工具条断开，避免误触退出。
        }
    }

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            when (intent.action) {
                SessionController.USB_PERMISSION_ACTION -> {
                    val granted = intent.getBooleanExtra(
                        UsbManager.EXTRA_PERMISSION_GRANTED,
                        false
                    )
                    controller.onAccessoryPermission(granted, intent.getAccessory())
                }

                UsbManager.ACTION_USB_ACCESSORY_ATTACHED -> controller.onAccessoryAttached(null)
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> controller.onAccessoryDetached()
            }
        }
    }

    private val debugReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (!BuildConfig.DEBUG) return
            when (intent.action) {
                "app.mirage.DEBUG_USB_ATTACHED" -> controller.onFakeAccessory(true)
                "app.mirage.DEBUG_USB_DETACHED" -> controller.onFakeAccessory(false)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        ContextCompat.registerReceiver(
            this,
            usbReceiver,
            IntentFilter().apply {
                addAction(SessionController.USB_PERMISSION_ACTION)
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

        onBackPressedDispatcher.addCallback(this, backCallback)

        val preferences = getSharedPreferences("mirage", Context.MODE_PRIVATE)
        controller = SessionController(this, mainHandler, preferences) { enabled ->
            setKeepScreenOn(enabled)
        }

        setContent {
            val ui by controller.ui.collectAsState()
            val context = LocalContext.current
            var dock by remember { mutableStateOf(DockState()) }

            SideEffect {
                backCallback.isEnabled = ui.inStream
            }

            LaunchedEffect(ui.inStream) {
                if (!ui.inStream) dock = DockState()
            }

            LaunchedEffect(dock.disconnectArmed) {
                while (dock.disconnectArmed) {
                    delay(500)
                    dock = dock.apply(DockIntent.Tick(System.currentTimeMillis())).state
                }
            }

            fun dispatchDock(intent: DockIntent) {
                if (intent == DockIntent.ToggleInput && ui.inputCaps and 1 == 0) {
                    Toasts.show(context, MirageStrings.INPUT_UNAVAILABLE)
                    return
                }
                // 本地 DockState 的开关字段可能落后于持久化/服务端状态，点击前先同步。
                val synced = dock.copy(
                    debugOn = ui.debugOn,
                    inputOn = ui.inputOn,
                    keyboardOn = ui.keyboardVisible
                )
                val result = synced.apply(intent)
                dock = result.state
                result.toasts.forEach { Toasts.show(context, it) }
                when (intent) {
                    DockIntent.ToggleDebug -> controller.setDebugOn(result.state.debugOn)
                    DockIntent.ToggleInput -> controller.setInputOn(result.state.inputOn)
                    DockIntent.ToggleKeyboard -> controller.toggleKeyboard()
                    is DockIntent.RequestDisconnect ->
                        if (result.disconnect) controller.disconnect()
                    else -> Unit
                }
            }

            MaterialTheme {
                Box(modifier = Modifier.fillMaxSize()) {
                    if (ui.inStream) {
                        StreamScreen(
                            ui = ui,
                            stats = controller.stats,
                            dock = dock,
                            onDockIntent = { dispatchDock(it) },
                            onInputFrame = { controller.inputFrame(it) },
                            onSurfaceReady = { view, newSurface ->
                                controller.onSurfaceReady(view, newSurface)
                            },
                            onSurfaceDestroyed = { controller.onSurfaceDestroyed() }
                        )
                    } else {
                        ConnectScreen(
                            ui = ui,
                            onMode = { controller.switchTransport(it) },
                            onConnect = { fields ->
                                controller.connectTo(fields.host, fields.port, fields.fingerprintHex)
                            },
                            onDisconnect = { controller.disconnect() }
                        )
                    }
                }
            }
        }

        controller.attachKeyboard()
        controller.start()
        hideSystemBars()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            controller.onAccessoryAttached(intent.getAccessory())
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemBars()
        }
    }

    override fun onResume() {
        super.onResume()
        controller.onResume()
        controller.updateScreen()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        controller.updateScreen()
    }

    override fun onPause() {
        controller.onPause()
        super.onPause()
    }

    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (controller.dispatchKeyEvent(event)) return true
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (controller.dispatchKeyEvent(event)) return true
        return super.onKeyUp(keyCode, event)
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
        controller.close()
        super.onDestroy()
    }

    private fun Intent.getAccessory(): UsbAccessory? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
        } else {
            @Suppress("DEPRECATION")
            getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
        }
}