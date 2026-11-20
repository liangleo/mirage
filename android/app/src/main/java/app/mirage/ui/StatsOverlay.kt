package app.mirage.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import app.mirage.net.StatsSnapshot
import app.mirage.net.StreamStats
import kotlinx.coroutines.delay

@Composable
fun StatsOverlay(
    stats: StreamStats,
    transportName: String,
    videoWidth: Int,
    videoHeight: Int
) {
    var snapshot by remember { mutableStateOf(StatsSnapshot()) }
    LaunchedEffect(Unit) {
        while (true) {
            snapshot = stats.snapshot()
            delay(500)
        }
    }
    val lines = StatsFormatter.format(snapshot, transportName, videoWidth, videoHeight)

    BoxWithConstraints {
        val width = minOf(maxWidth, MirageDimens.overlayWidth)
        Column(
            modifier = Modifier
                .width(width)
                .background(
                    color = MirageColors.OverlayBackground,
                    shape = RoundedCornerShape(MirageDimens.overlayRadius)
                )
                .padding(
                    horizontal = MirageDimens.overlayPaddingH,
                    vertical = MirageDimens.overlayPaddingV
                ),
            verticalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            Row {
                Text(lines.first, color = MirageColors.White, fontSize = MirageText.overlayLine)
                Spacer(Modifier.weight(1f))
                Text(lines.transport, color = MirageColors.OverlayLabel, fontSize = MirageText.overlayCaption)
            }
            Row {
                Text(lines.second, color = MirageColors.OverlayValue, fontSize = MirageText.overlayLine)
                Spacer(Modifier.weight(1f))
                Text(lines.p95, color = MirageColors.OverlayLabel, fontSize = MirageText.overlayCaption)
            }
        }
    }
}