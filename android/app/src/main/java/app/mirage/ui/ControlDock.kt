package app.mirage.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import app.mirage.session.DockIntent
import app.mirage.session.DockState

@Composable
fun ControlDock(
    dock: DockState,
    debugOn: Boolean,
    inputOn: Boolean,
    keyboardOn: Boolean,
    modifier: Modifier = Modifier,
    onIntent: (DockIntent) -> Unit
) {
    Column(
        modifier = modifier.padding(
            end = MirageDimens.dockEnd,
            bottom = MirageDimens.dockBottom
        ),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(MirageDimens.toolSpacing)
    ) {
        if (dock.open) {
            ToolButton(
                DockAction.DEBUG,
                if (debugOn) DockVisualState.ACTIVE else DockVisualState.DISABLED,
                "调试"
            ) { onIntent(DockIntent.ToggleDebug) }
            ToolButton(
                DockAction.INPUT,
                if (inputOn) DockVisualState.ACTIVE else DockVisualState.DISABLED,
                "输入"
            ) { onIntent(DockIntent.ToggleInput) }
            ToolButton(
                DockAction.KEYBOARD,
                if (keyboardOn) DockVisualState.ACTIVE else DockVisualState.DISABLED,
                "键盘"
            ) { onIntent(DockIntent.ToggleKeyboard) }
            ToolButton(
                DockAction.DISCONNECT,
                if (dock.disconnectArmed) DockVisualState.ACTIVE else DockVisualState.DISABLED,
                "断开"
            ) { onIntent(DockIntent.RequestDisconnect(System.currentTimeMillis())) }
            ToolButton(DockAction.CLOSE, DockVisualState.NORMAL, "收起") {
                onIntent(DockIntent.ToggleOpen)
            }
        } else {
            ToolButton(DockAction.SETTINGS, DockVisualState.NORMAL, "设置") {
                onIntent(DockIntent.ToggleOpen)
            }
        }
    }
}

@Composable
private fun ToolButton(
    action: DockAction,
    state: DockVisualState,
    description: String,
    onClick: () -> Unit
) {
    val size = MirageDimens.iconSize
    Box(
        modifier = Modifier
            .size(MirageDimens.toolButton)
            .background(MirageDimens.buttonBackground, RoundedCornerShape(MirageDimens.toolRadius))
            .border(1.dp, MirageDimens.buttonBorder, RoundedCornerShape(MirageDimens.toolRadius))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center
    ) {
        Image(
            painter = painterResource(iconRes(action, state)),
            contentDescription = description,
            modifier = Modifier.size(size)
        )
    }
}