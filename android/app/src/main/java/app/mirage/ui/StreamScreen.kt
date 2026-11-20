package app.mirage.ui

import android.view.Surface
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import app.mirage.input.TouchFrame
import app.mirage.net.StreamStats
import app.mirage.session.DockIntent
import app.mirage.session.DockState
import app.mirage.session.SessionUiState

@Composable
fun StreamScreen(
    ui: SessionUiState,
    stats: StreamStats,
    dock: DockState,
    onDockIntent: (DockIntent) -> Unit,
    onInputFrame: (TouchFrame) -> Unit,
    onSurfaceReady: (AspectSurfaceView, Surface) -> Unit,
    onSurfaceDestroyed: () -> Unit
) {
    val context = LocalContext.current
    LaunchedEffect(ui.inputReason) {
        ui.inputReason?.let { Toasts.show(context, it) }
    }

    Box(modifier = Modifier.fillMaxSize().background(MirageColors.Black)) {
        VideoView(
            onSurfaceReady = onSurfaceReady,
            onSurfaceDestroyed = onSurfaceDestroyed,
            inputEnabled = ui.connected && ui.inputAllowed && ui.inputOn && ui.overlay == null,
            onInputFrame = onInputFrame
        )

        if (ui.debugOn) {
            Box(
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(12.dp)
            ) {
                StatsOverlay(
                    stats = stats,
                    transportName = ui.transportName.ifBlank { ui.transportInfo }.ifBlank { MirageStrings.DISCONNECTED },
                    videoWidth = ui.videoWidth,
                    videoHeight = ui.videoHeight
                )
            }
        }

        if (ui.overlay == null) {
            ControlDock(
                dock = dock,
                debugOn = ui.debugOn,
                inputOn = ui.inputOn,
                keyboardOn = ui.keyboardVisible,
                modifier = Modifier.align(Alignment.BottomEnd),
                onIntent = onDockIntent
            )
        }

        ui.overlay?.let { overlay ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(MirageColors.WaitingBackground),
                contentAlignment = Alignment.Center
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(14.dp)
                ) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(56.dp),
                        color = MirageColors.White
                    )
                    Text(
                        overlay.message,
                        color = MirageColors.White,
                        fontSize = MirageText.waiting
                    )
                    Spacer(modifier = Modifier.size(14.dp))
                    Text(
                        "${MirageStrings.WAITING_RECONNECT} ${overlay.remainSec}s",
                        color = MirageColors.OverlayLabel,
                        fontSize = MirageText.waitingCountdown
                    )
                }
            }
        }
    }
}