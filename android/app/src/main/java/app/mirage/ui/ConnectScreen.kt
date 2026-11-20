package app.mirage.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.mirage.net.MdnsDiscovery
import app.mirage.net.TransportMode
import app.mirage.session.ConnectFields
import app.mirage.session.ConnectForm
import app.mirage.session.ConnectValidation
import app.mirage.session.SessionUiState
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions

private data class ConnectActions(
    val onMode: (TransportMode) -> Unit,
    val onConnect: (ConnectFields) -> Unit,
    val onDisconnect: () -> Unit,
    val onImport: () -> Unit,
    val onDiscover: () -> Unit,
    val onScan: () -> Unit
)

@Composable
fun ConnectScreen(
    ui: SessionUiState,
    onMode: (TransportMode) -> Unit,
    onConnect: (ConnectFields) -> Unit,
    onDisconnect: () -> Unit
) {
    val context = LocalContext.current
    var host by remember { mutableStateOf(ui.savedHost) }
    var port by remember {
        mutableStateOf(
            if (ui.savedPort > 0) ui.savedPort.toString()
            else ConnectForm.defaultPort(ui.transportMode).toString()
        )
    }
    var fingerprintHex by remember { mutableStateOf(ui.savedFingerprint) }
    var pairLink by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var discovering by remember { mutableStateOf(false) }
    val discovery = remember { MdnsDiscovery(context) }
    val fieldColors = OutlinedTextFieldDefaults.colors(
        focusedTextColor = MirageColors.LightText,
        unfocusedTextColor = MirageColors.LightText,
        focusedBorderColor = MirageColors.Blue,
        unfocusedBorderColor = MirageColors.LightBorder,
        focusedPlaceholderColor = MirageColors.LightPlaceholder,
        unfocusedPlaceholderColor = MirageColors.LightPlaceholder,
        cursorColor = MirageColors.Blue
    )

    DisposableEffect(Unit) {
        onDispose { discovery.stop() }
    }

    fun applyPairing(link: String) {
        val fields = ConnectForm.fromPairing(link)
        if (fields == null) {
            message = "配对链接无效"
        } else {
            host = fields.host
            port = fields.port.toString()
            fingerprintHex = fields.fingerprintHex
            message = "已导入配对信息"
        }
    }

    fun pickMode(mode: TransportMode) {
        onMode(mode)
        if (mode == TransportMode.TCP) {
            host = "127.0.0.1"
            port = "7777"
        } else if (mode == TransportMode.WIFI || mode == TransportMode.AUTO) {
            val current = port.toIntOrNull()
            if (current == null || current <= 0 || current == 7777) {
                port = ConnectForm.defaultPort(mode).toString()
            }
        }
    }

    val scanner = rememberLauncherForActivityResult(ScanContract()) { result ->
        val fields = result.contents?.let { ConnectForm.fromPairing(it) }
        if (fields == null) {
            message = "二维码不是有效的 Mirage 配对码"
        } else {
            host = fields.host
            port = fields.port.toString()
            fingerprintHex = fields.fingerprintHex
            message = "已导入配对信息"
        }
    }

    fun connect() {
        when (val result = ConnectForm.validate(host, port, fingerprintHex, ui.transportMode)) {
            is ConnectValidation.Invalid -> message = result.message
            is ConnectValidation.Valid -> {
                message = null
                onConnect(result.fields)
            }
        }
    }

    val footerLabel = when (ui.transportMode) {
        TransportMode.AUTO -> if (ui.inStream && ui.transportInfo.isNotBlank()) ui.transportInfo else "自动选择"
        TransportMode.WIFI -> "Wi-Fi ${host.ifBlank { "—" }}:${port.ifBlank { "7778" }}"
        TransportMode.TCP -> "TCP 127.0.0.1:7777"
        TransportMode.USB -> "USB"
    }

    val actions = ConnectActions(
        onMode = { pickMode(it) },
        onConnect = onConnect,
        onDisconnect = onDisconnect,
        onImport = { applyPairing(pairLink) },
        onDiscover = {
            discovering = true
            message = "正在发现 Mac…"
            discovery.start(
                onFound = { foundHost, foundPort, attributes ->
                    discovering = false
                    discovery.stop()
                    host = foundHost
                    port = foundPort.toString()
                    val advertised = attributes["fp"]
                    val name = attributes["name"] ?: foundHost
                    if (!advertised.isNullOrBlank() && advertised == fingerprintHex) {
                        message = "发现 $name，自动连接…"
                        onConnect(ConnectFields(foundHost, foundPort, fingerprintHex))
                    } else {
                        message = "发现 $name，需扫码确认指纹"
                    }
                },
                onError = { reason ->
                    discovering = false
                    message = reason
                }
            )
        },
        onScan = {
            message = null
            scanner.launch(
                ScanOptions()
                    .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                    .setPrompt("扫描 Mac 上的 Mirage 配对二维码")
                    .setBeepEnabled(false)
                    .setOrientationLocked(true)
            )
        }
    )

    BoxWithConstraints(
        modifier = Modifier
            .fillMaxSize()
            .background(MirageColors.White)
            .windowInsetsPadding(WindowInsets.safeDrawing)
    ) {
        if (maxHeight < 500.dp) {
            Row(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    ConnectHeader(ui.status, compact = true)
                    HostRow(host, port, fieldColors, onHost = { host = it }, onPort = { port = it })
                    PairField(pairLink, fieldColors, onChange = { pairLink = it })
                    ConnectFooter(footerLabel, compact = true)
                }
                Column(
                    modifier = Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    ConnectModes(ui.transportMode, discovering, actions)
                    ConnectActionsRow(ui.connecting, ::connect, onDisconnect)
                    ConnectMessage(message, compact = true)
                }
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(MirageDimens.screenPadding),
                verticalArrangement = Arrangement.spacedBy(MirageDimens.rowSpacing),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                ConnectHeader(ui.status, compact = false)
                HostRow(host, port, fieldColors, onHost = { host = it }, onPort = { port = it })
                PairField(pairLink, fieldColors, onChange = { pairLink = it })
                ConnectModes(ui.transportMode, discovering, actions)
                ConnectActionsRow(ui.connecting, ::connect, onDisconnect)
                ConnectMessage(message, compact = false)
                if (fingerprintHex.isNotBlank()) {
                    Text(
                        "指纹 ${fingerprintHex.take(8)}…",
                        color = MirageColors.Caption,
                        fontSize = MirageText.caption
                    )
                }
                ConnectFooter(footerLabel, compact = false)
            }
        }
    }
}

@Composable
private fun ConnectHeader(status: String, compact: Boolean) {
    Text(
        MirageStrings.TITLE,
        color = MirageColors.LightText,
        fontSize = if (compact) 20.sp else MirageText.title,
        fontWeight = FontWeight.Bold
    )
    Text(
        status,
        color = MirageColors.LightStatus,
        fontSize = if (compact) 13.sp else MirageText.status
    )
}

@Composable
private fun HostRow(
    host: String,
    port: String,
    colors: androidx.compose.material3.TextFieldColors,
    onHost: (String) -> Unit,
    onPort: (String) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)
    ) {
        Text(
            MirageStrings.HOST_LABEL,
            color = MirageColors.LightText,
            fontSize = MirageText.mode,
            modifier = Modifier.width(56.dp)
        )
        OutlinedTextField(
            value = host,
            onValueChange = onHost,
            placeholder = { Text("192.168.1.10") },
            singleLine = true,
            colors = colors,
            modifier = Modifier.weight(1f)
        )
        OutlinedTextField(
            value = port,
            onValueChange = onPort,
            placeholder = { Text(MirageStrings.PORT_HINT) },
            singleLine = true,
            colors = colors,
            modifier = Modifier.width(90.dp)
        )
    }
}

@Composable
private fun PairField(
    pairLink: String,
    colors: androidx.compose.material3.TextFieldColors,
    onChange: (String) -> Unit
) {
    OutlinedTextField(
        value = pairLink,
        onValueChange = onChange,
        placeholder = { Text(MirageStrings.PAIR_LINK_HINT) },
        singleLine = true,
        colors = colors,
        modifier = Modifier.fillMaxWidth()
    )
}

@Composable
private fun ConnectModes(mode: TransportMode, discovering: Boolean, actions: ConnectActions) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ModeButton(MirageStrings.IMPORT_PAIR, false, actions.onImport)
        ModeButton(if (discovering) "搜索中…" else MirageStrings.DISCOVER, false, actions.onDiscover)
        ModeButton(MirageStrings.SCAN, false, actions.onScan)
    }
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically
    ) {
        listOf(
            TransportMode.AUTO to "AUTO",
            TransportMode.WIFI to "Wi-Fi",
            TransportMode.TCP to "TCP",
            TransportMode.USB to "USB"
        ).forEach { (item, label) ->
            ModeButton(label, mode == item) { actions.onMode(item) }
        }
    }
}

@Composable
private fun ConnectActionsRow(connecting: Boolean, onConnect: () -> Unit, onDisconnect: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterHorizontally)
    ) {
        Button(
            onClick = onConnect,
            enabled = !connecting,
            colors = ButtonDefaults.buttonColors(containerColor = MirageColors.Blue),
            modifier = Modifier.width(MirageDimens.connectButtonWidth)
        ) {
            Text(MirageStrings.CONNECT)
        }
        Button(
            onClick = onDisconnect,
            colors = ButtonDefaults.buttonColors(containerColor = MirageColors.Dark),
            modifier = Modifier.width(MirageDimens.connectButtonWidth)
        ) {
            Text(MirageStrings.DISCONNECT)
        }
    }
}

@Composable
private fun ConnectMessage(message: String?, compact: Boolean) {
    if (message == null) return
    Text(message, color = MirageColors.LightStatus, fontSize = if (compact) 11.sp else MirageText.caption)
}

@Composable
private fun ConnectFooter(transportInfo: String, compact: Boolean) {
    Spacer(Modifier.height(if (compact) 0.dp else 4.dp))
    Text(
        transportInfo.ifBlank { MirageStrings.DISCONNECTED },
        color = MirageColors.Caption,
        fontSize = MirageText.caption
    )
}

@Composable
private fun ModeButton(label: String, selected: Boolean, onClick: () -> Unit) {
    TextButton(onClick = onClick) {
        Text(
            label,
            color = if (selected) MirageColors.Blue else MirageColors.Gray,
            fontSize = MirageText.mode
        )
    }
}