# Android 客户端对齐鸿蒙侧实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Android 客户端在协议、传输、会话与 UI 布局上与鸿蒙原生客户端一致，并修复当前 UDP 不兼容。

**Architecture:** 保留现有的 `MirageClient`（连接读循环）、`VideoDecoder`（MediaCodec）与输入链路；新增纯逻辑 `SessionMachine` + 薄副作用层 `SessionController`；把 `MainActivity` 拆成薄壳与 Compose 页面；UDP 接收器按鸿蒙语义重写交付/NACK/切换条件。

**Tech Stack:** Kotlin 2.2 / AGP 8.13 / Jetpack Compose（M3 BOM 2025.06.00）/ MediaCodec / java.net（TCP、UDP、TLS）/ JUnit4。

**Spec:** [2026-11-19-mirage-android-alignment-design.md](../specs/2026-11-19-mirage-android-alignment-design.md)

**Status:** 已实施（2026-11-19）。Android 单测 144/144、lint、assembleDebug 通过；vivo PD2309 真机验证 Wi‑Fi UDP（e2e/p95）、AUTO 插线切 USB、USB 掉线回 Wi‑Fi UDP；浅色连接页与横屏两栏布局已确认；旋转 HELLO/解码器重建链路已用真机日志确认。真机旋转已验证（横竖分辨率切换生效）。物理插回 USB 的自动回切待终验。

## Global Constraints

- **Compose ONLY**：禁止 XML 布局、`findViewById`、Material 2；图标例外见 Task 8（项目自带 PNG）。
- 版本以 `android/app/build.gradle.kts` 为准；**不新增依赖**、不引入 native 库、不限制 ABI。
- 所有新颜色/间距/字号先进 `ui/Theme.kt` 令牌，再引用；不散落 `Color(0xFF...)`/魔法 `dp`。
- 用户可见文案与鸿蒙逐字一致（见 Spec §7）；文案集中在 `ui/Strings.kt`。
- 不改协议、不改 Mac 端；`proto_ver=1`，未知消息类型继续忽略。
- `minSdk 26`；`KEY_LOW_LATENCY`（30+）、`KEY_PRIORITY`（28+）等守卫保持 try/catch。
- 单测命令（本机 `java` 不在 PATH 时先设 `JAVA_HOME=~/Library/Java/JavaVirtualMachines/corretto-17.0.18/Contents/Home`）：
  `cd android && ./gradlew :app:testDebugUnitTest`
- 基线（2026-11-19）：`UdpProtocolTest.datagramMatchesSharedVectorAndRoundTrips` 与 `nackMatchesSharedVector` 失败，因为共享向量已是 24B 头。Task 1 必须先修绿。
- 设备验证优先真机；无真机时 UI 用模拟器，UDP/AOA/性能项在交付说明中标注未验证。

## Review Focus

- 畸形/截断/超大 UDP 数据报：必须忽略并继续，不得崩溃或卡住接收线程。（Task 1、2）
- 重复片、迟到重传、旧帧到达：不得重复交付或倒退 `lastDelivered`。（Task 2）
- 重连/旋转/切通道竞态：旧 generation 的回调必须全部丢弃。（Task 4 的 `staleConnectionClosedIsIgnored` + Task 5/7 回归）
- USB 授权拒绝、切换 USB 中途拔线、AUTO 来回抖动：不得死循环弹授权或无限切换。（Task 6）
- 无样本统计（刚连接/全丢包）：e2e/p95 显示 `--`，窄屏浮层不溢出。（Task 11）

---

### Task 1: UDP 24B 头、采集时间戳与 p95

**Files:**
- Modify: `android/app/src/main/java/app/mirage/net/UdpProtocol.kt`
- Modify: `android/app/src/main/java/app/mirage/net/UdpVideoReceiver.kt`
- Modify: `android/app/src/main/java/app/mirage/net/StreamStats.kt`
- Test: `android/app/src/test/java/app/mirage/net/UdpProtocolTest.kt`
- Test: `android/app/src/test/java/app/mirage/net/UdpVideoReceiverTest.kt`
- Test: `android/app/src/test/java/app/mirage/net/LivenessTest.kt`（实际是 StreamStats 测试）

**Interfaces:**
- Produces:
  - `UdpVideoHeader(seq, frameID, fragIndex, fragCount, flags, reserved, payloadLength, captureTsMicros: Long = 0)`，`SIZE = 24`
  - `StatsSnapshot.e2eP95Ms: Long`（无样本为 `-1`）
  - `StreamStats.setE2eMs(value: Long)` 同时维护最近 300 个样本

- [ ] **Step 1: 更新共享向量测试，确认失败**

`protocol/vectors.json` 的 datagram 向量未列出 `captureTsMicros` 字段，但 hex 中已含 8 个零字节。测试构造 header 时使用默认值 0，断言编码结果等于向量 hex，解码后 `header.captureTsMicros == 0`。NACK 测试无需改字段，但编码长度应随 24B 头变化。

新增：

```kotlin
@Test fun captureTimestampRoundTrips()  // captureTsMicros = 1_700_000_000_123
@Test fun truncated24ByteHeaderIsRejected()  // 23 字节 → ProtocolException
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.net.UdpProtocolTest'`
Expected: FAIL，`udp length mismatch` 或数组长度 expected 28 / actual 20。

- [ ] **Step 3: 实现 24B 头**

`UdpVideoHeader.SIZE = 24`；`encode` 在 `payloadLength` 后追加 `putLong(captureTsMicros)`；`decode` 用 `buffer.getLong(16)` 读取；`payload` 起点改为 `SIZE`。

- [ ] **Step 4: UDP 帧传递时间戳**

`UdpVideoReceiver.Partial` 增加 `captureTsMicros: Long`（首片设置，后续一致才保留；不一致则以首片为准）；`assemble` 填入 `VideoHeader.captureTimestampMicros`。

测试：

```kotlin
@Test fun captureTimestampReachesVideoFrame()
@Test fun duplicateFragmentDoesNotChangeTimestamp()
```

- [ ] **Step 5: StreamStats p95**

先写测试：

```kotlin
@Test fun p95UsesNearestRankOver300Samples()
@Test fun p95IsMinusOneWithoutSamples()
@Test fun p95IgnoresNegativeE2e()
```

实现：`ArrayDeque<Long>`，上限 300；`setE2eMs` 仅在 `>= 0` 时入队；`snapshot` 中排序取 `ceil(0.95*n)-1`。

- [ ] **Step 6: 全量单测并提交**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: 全绿（含原 62 个测试）。

```bash
git add android/app/src/main/java/app/mirage/net android/app/src/test/java/app/mirage/net
git commit -m "fix(android): align UDP header with the 24-byte capture-timestamp format"
```

---

### Task 2: UDP 切换、顺序交付与 NACK 语义

**Files:**
- Modify: `android/app/src/main/java/app/mirage/net/UdpVideoReceiver.kt`
- Modify: `android/app/src/main/java/app/mirage/net/MirageClient.kt`
- Test: `android/app/src/test/java/app/mirage/net/UdpVideoReceiverTest.kt`

**Interfaces:**
- Consumes: Task 1 的 24B 头与 `captureTsMicros`
- Produces:
  - `onReady` 仅在**首个完整帧**交付时触发一次（HELLO ACK 不再触发）
  - `UdpVideoReceiver.onKeyframeNeeded: () -> Unit` 构造参数
  - `MirageClient.requestUsb()`（Task 3 使用）

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun helloAckDoesNotBecomeReady()
@Test fun firstCompleteFrameTriggersReadyOnce()
@Test fun framesAreDeliveredInFrameIdOrder()
@Test fun outOfOrderAsyncFrameWaitsForHead()
@Test fun missingHeadAbandonedAfter200msAndRequestsKeyframe()
@Test fun nackIsSentAtMostThreeRounds()
@Test fun failsAfter30sWithoutAnyFrame()
@Test fun failsAfter10sSilenceOnceStreaming()
@Test fun lateDuplicateAfterDeliveryIsIgnored()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.net.UdpVideoReceiverTest'`
Expected: 新增用例 FAIL（ready/skip/NACK 计数不符）。

- [ ] **Step 3: 重写接收器状态**

- `Partial` 增加 `receivedAtNanos`、`eofSeen`、`nackRounds`。
- 维护 `nextDeliverId: Long`（初始为收到的第一个 frameID）。`feed` 只存片；`deliverReady(now)` 从 `nextDeliverId` 起连续交付；头部缺失超过 200ms → `nextDeliverId = 最小已见 frameID`，并触发 `onKeyframeNeeded()`。
- NACK：当某帧 `eofSeen` 或出现更大的 frameID 后 6ms，且 `nackRounds < 3`，发送缺失片 bitmap；每轮间隔 ≥10ms。
- 失败：`start` 后 30s 无完整帧；或首帧后 10s 无任何数据报 → `onFailure("UDP 无响应")`。
- `onReady` 在首次成功交付时调用；之后不再调用。
- `stop()` 重置全部状态。

- [ ] **Step 4: TCP 视频门控**

`MirageClient` 增加 `udpActive`：UDP `onReady` 时置 true；`onFailure` 置 false；`onVideo` 的 TCP 分支在 `udpActive` 时忽略（仍更新 liveness）。`onKeyframeNeeded` → `requestKeyframe()`。

- [ ] **Step 5: 运行测试**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.net.UdpVideoReceiverTest'`
Expected: PASS。

- [ ] **Step 6: 全量测试并提交**

Run: `cd android && ./gradlew :app:testDebugUnitTest`

```bash
git add android/app/src/main/java/app/mirage/net android/app/src/test/java/app/mirage/net/UdpVideoReceiverTest.kt
git commit -m "fix(android): deliver UDP frames in order and follow the harmony NACK policy"
```

---

### Task 3: USB_REQUEST 与 FEEDBACK 真实字段

**Files:**
- Modify: `android/app/src/main/java/app/mirage/net/Protocol.kt`
- Modify: `android/app/src/main/java/app/mirage/net/MirageClient.kt`
- Modify: `android/app/src/main/java/app/mirage/net/FeedbackReporter.kt`
- Modify: `android/app/src/main/java/app/mirage/video/VideoDecoder.kt`
- Test: `android/app/src/test/java/app/mirage/net/ProtocolTest.kt`
- Test: `android/app/src/test/java/app/mirage/net/FeedbackTest.kt`

**Interfaces:**
- Produces:
  - `Ctrl.USB_REQUEST = 7`
  - `MirageClient.requestUsb()`
  - `VideoDecoder.queueDepth: Int`、`VideoDecoder.droppedFrames: Long`
  - `FeedbackReporter(..., droppedFrames: () -> Int, queueDepth: () -> Int, arrivalDelayMS: () -> Int)`

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun ctrlUsbRequestEncodesAsType6Payload7()
@Test fun feedbackCarriesDroppedQueueAndArrival()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.net.ProtocolTest'`

- [ ] **Step 3: 实现**

- `Ctrl.USB_REQUEST = 7`；`MirageClient.requestUsb()` 发 `CTRL` 单字节 7。
- `FeedbackReporter.build` 使用注入的三个 supplier，替换常量 0；`arrivalDelayMS` 取当前 e2e（无样本为 0），`queueDepth` 取解码队列长度，`droppedFrames` 取自上次反馈以来的解码丢帧数。
- `VideoDecoder` 暴露 `queueDepth`（`queue.size()`）与累计丢帧（复用 `stats` 或本地计数）。
- `MirageClient` 组装 reporter 时传入上述 supplier；HELLO 的 `features` 保持 0（Mac 不消费，见 Spec §10）。

- [ ] **Step 4: 测试通过并提交**

Run: `cd android && ./gradlew :app:testDebugUnitTest`

```bash
git add android/app/src/main/java/app/mirage android/app/src/test/java/app/mirage/net
git commit -m "feat(android): add USB_REQUEST and fill the feedback adaptation fields"
```

---

### Task 4: 纯会话状态机与重连策略

**Files:**
- Create: `android/app/src/main/java/app/mirage/session/SessionState.kt`
- Create: `android/app/src/main/java/app/mirage/session/SessionMachine.kt`
- Create: `android/app/src/main/java/app/mirage/session/ReconnectPolicy.kt`
- Test: `android/app/src/test/java/app/mirage/session/SessionMachineTest.kt`
- Test: `android/app/src/test/java/app/mirage/session/ReconnectPolicyTest.kt`

**Interfaces:**
- Produces:

```kotlin
sealed interface SessionState {
    data object Idle : SessionState
    data object Selecting : SessionState
    data object Connecting : SessionState
    data class Streaming(val config: SessionConfig) : SessionState
    data class Recovering(val reason: String) : SessionState
    data object Stopped : SessionState
}

sealed interface SessionEvent { /* Connect, Select, Config, Closed, Retry,
    Disconnect, TransportChanged, ScreenChanged, PermanentError */ }

sealed interface SessionAction { /* OpenTransport, CloseTransport, StopDecoder,
    StartDecoder, RequestKeyframe, PollUsb */ }

data class MachineState(
    val state: SessionState = SessionState.Idle,
    val attempts: Int = 0,
    val generation: Long = 0,
    val backoffMs: Long = 0,
    val actions: List<SessionAction> = emptyList()
)

fun reduce(state: MachineState, event: SessionEvent): MachineState
```

- `ReconnectPolicy.innerBackoffMs(attempt: Int): Long` = `min(500L shl (attempt-1), 5_000L)`
- `ReconnectPolicy.innerExhausted(attempts: Int): Boolean` = `attempts > 10`
- `ReconnectPolicy.OUTER_RETRY_MS = 5_000L`、`OUTER_WINDOW_MS = 300_000L`

- [ ] **Step 1: 写失败测试（状态机）**

```kotlin
@Test fun connectFromIdleSelectsAndBumpsGeneration()
@Test fun selectWaitUsbStaysIdleAndPolls()
@Test fun selectTransportEntersConnecting()
@Test fun configStartsDecoderAndRequestsKeyframe()
@Test fun closedBelowLimitEntersRecoveringWithBackoff()
@Test fun closedAboveLimitStops()
@Test fun retryFromRecoveringSelects()
@Test fun disconnectStopsAndCloses()
@Test fun transportChangedSelects()
@Test fun permanentErrorStopsWithoutRetry()
@Test fun staleConnectionClosedIsIgnored()
```

- [ ] **Step 2: 写失败测试（策略）**

```kotlin
@Test fun backoffDoublesUpToFiveSeconds()
@Test fun innerExhaustsAfterTenAttempts()
@Test fun outerWindowIsFiveMinutes()
```

- [ ] **Step 3: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.session.*'`
Expected: 编译失败（类不存在）。

- [ ] **Step 4: 最小实现**

按 Spec §6.1 实现 reducer；不接触 Android API，`SessionConfig` 用现有 `net.SessionConfig`。

- [ ] **Step 5: 测试通过并提交**

Run: `cd android && ./gradlew :app:testDebugUnitTest`

```bash
git add android/app/src/main/java/app/mirage/session android/app/src/test/java/app/mirage/session
git commit -m "feat(android): add an explicit session state machine"
```

---

### Task 5: SessionController 接管连接、重连与生命周期

**Files:**
- Create: `android/app/src/main/java/app/mirage/session/SessionController.kt`
- Create: `android/app/src/main/java/app/mirage/session/SessionUiState.kt`
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Test: 无新增纯逻辑测试；以编译 + 现有测试 + 真机连接回归为准（本任务只搬运，不改行为）

**Interfaces:**
- Consumes: Task 4 的 `SessionMachine`
- Produces:
  - `class SessionController(activity: ComponentActivity, main: Handler, prefs: SharedPreferences)` 
  - `val ui: StateFlow<SessionUiState>`
  - `fun connect()`, `fun disconnect()`, `fun switchTransport(mode)`, `fun updateScreen(w,h,rotation)`
  - `UiState` 字段：`state`、`status`、`transportLabel`、`overlay(remainSec)`、`config`、`inputCaps`、`inputAllowed`、`inputReason`、`debugOn`、`inputOn`
  - `val stats: StreamStats`

- [ ] **Step 1: 建立控制器骨架**

把 `MainActivity` 中以下成员原样迁入：`client`、`clientGeneration`、`decoder`、`config`、`pendingKeyframe`、`usingUsb`、`reconnectRunnable`、`reconnectAttempts`、`lastHost/lastPort`、输入门控与 `keyboardBridge` 的创建/释放。`MainActivity` 只保留窗口、USB 广播注册、`setContent` 与 `onConfigurationChanged`。

- [ ] **Step 2: 状态通过 StateFlow 暴露**

`MainActivity` 用 `collectAsState()` 渲染；删除 Activity 内对应的 `mutableStateOf` 字段。所有回调经 generation 校验后更新 `ui`。

- [ ] **Step 3: 行为保持不变的回归**

Run: `cd android && ./gradlew :app:testDebugUnitTest`
Expected: 全绿。

真机/模拟器：连接 Wi-Fi → 出画面 → 断开 → 重连一次。行为应与改造前相同（本任务不引入 AUTO 新行为，也不改 UI）。

- [ ] **Step 4: 提交**

```bash
git add android/app/src/main/java/app/mirage
git commit -m "refactor(android): move session ownership out of MainActivity"
```

---

### Task 6: AUTO 阶段链、USB 回切与 USB_REQUEST

**Files:**
- Create: `android/app/src/main/java/app/mirage/session/AutoPlan.kt`
- Modify: `android/app/src/main/java/app/mirage/session/SessionController.kt`
- Test: `android/app/src/test/java/app/mirage/session/AutoPlanTest.kt`

**Interfaces:**
- Produces:

```kotlin
data class TransportPlan(val kind: TransportKind, val host: String? = null, val port: Int = 0)
object AutoPlan {
    fun select(mode: TransportMode, stage: Int, hasAccessory: Boolean,
               host: String?, port: Int): TransportPlan?
    fun nextStage(stage: Int): Int            // 0 → 1 → 2，封顶 2
    fun shouldPollUsb(mode: TransportMode, streaming: Boolean, kind: TransportKind): Boolean
    fun shouldSendUsbRequest(mode: TransportMode, streaming: Boolean, kind: TransportKind): Boolean
}

data class UsbSwitchState(val failures: Int = 0, val disabled: Boolean = false)
object UsbSwitchPolicy {
    const val MAX_FAILURES = 3
    fun onFailure(state: UsbSwitchState): UsbSwitchState   // 达到 3 次 → disabled
    fun onDetach(state: UsbSwitchState): UsbSwitchState    // 复位
    fun permissionDeniedIsPermanent(): Boolean              // true，不重新弹授权
}
```

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun autoPrefersUsb()                 // stage 0 + accessory → USB
@Test fun autoUsesWifiWhenConfigured()     // stage 0, no accessory, host → WIFI
@Test fun autoFallsBackToTcp()             // stage 0, no accessory, no host → TCP
@Test fun stageOneSkipsUsb()
@Test fun stageTwoIsTcp()
@Test fun explicitWifiNeverSwitchesToUsb() // shouldPollUsb/shouldSendUsbRequest false
@Test fun autoOnWifiPollsAndRequestsUsb()  // 两者 true
@Test fun autoOnUsbDoesNotRequestUsb()
@Test fun usbSwitchStopsAfterThreeFailures()
@Test fun usbDetachResetsSwitchFailures()
@Test fun permissionDeniedIsPermanent()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.session.AutoPlanTest'`

- [ ] **Step 3: 实现并接线**

- `select` 按 Spec §6.2 实现；mDNS 分支留在控制器（发现成功后再进入 stage 0 的 Wi-Fi）。
- 控制器：AUTO + Streaming(WIFI/TCP) 时每 3s 一次：轮询配件；有配件 → 停旧会话、等 300ms、`connectUsb()`；无配件 → `client.requestUsb()`。
- 连续 3 次 USB 切换失败后停止尝试；配件消失（detach）后计数复位。
- 失败时 `nextStage()` 推进；收到 `SESSION_CONFIG` 复位到 0。
- USB 模式下 `ACTION_USB_ACCESSORY_DETACHED` → `Closed("USB 已断开")`，进入等待重插。

- [ ] **Step 4: 全量测试并提交**

Run: `cd android && ./gradlew :app:testDebugUnitTest`

```bash
git add android/app/src/main/java/app/mirage/session android/app/src/test/java/app/mirage/session
git commit -m "feat(android): follow the harmony AUTO ladder and hand off to USB on demand"
```

---

### Task 7: 旋转重配置与解码器重建

**Files:**
- Modify: `android/app/src/main/AndroidManifest.xml`
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Modify: `android/app/src/main/java/app/mirage/session/SessionController.kt`
- Test: `android/app/src/test/java/app/mirage/session/ScreenChangeTest.kt`

**Interfaces:**
- Produces:
  - `ScreenSnapshot(width, height, rotation)`
  - `ScreenChange.shouldResendHello(prev: ScreenSnapshot, next: ScreenSnapshot): Boolean`
  - `SessionController.updateScreen(w, h, rotation)` → 变化时重发 HELLO

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun sameSizeAndRotationDoesNotResend()
@Test fun sizeChangeResends()
@Test fun rotationChangeResends()
@Test fun zeroSizeIsIgnored()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.session.ScreenChangeTest'`

- [ ] **Step 3: 实现**

- Manifest activity 增加 `android:configChanges="orientation|screenSize|smallestScreenSize|screenLayout|keyboardHidden|density"`。
- `MainActivity.onConfigurationChanged` → `controller.updateScreen(...)`；Compose 自然重排。
- `SessionController` 在 Streaming 时用现有连接重发 `Messages.encodeHello(buildHello())`，不关闭会话；未 Streaming 时只更新待发送的 HELLO 数据。
- 解码器重建：`onConfig` 若宽高与当前不同 → `decoder.release()`、`decoderSurface=null`、`maybeStartDecoder()`；同时 `surfaceView.applyVideoSize`。
- 服务端 execv 重启导致的断开走 `Recovering` 与外层重试，无需特判。

- [ ] **Step 4: 测试 + 提交流程**

Run: `cd android && ./gradlew :app:testDebugUnitTest`

```bash
git add android/app/src/main/AndroidManifest.xml android/app/src/main/java/app/mirage
git add android/app/src/test/java/app/mirage/session/ScreenChangeTest.kt
git commit -m "feat(android): resend HELLO on rotation without recreating the activity"
```

---

### Task 8: 主题令牌与图标资源

**Files:**
- Create: `android/app/src/main/java/app/mirage/ui/Theme.kt`
- Create: `android/app/src/main/java/app/mirage/ui/DockIcons.kt`
- Create: `android/app/src/main/java/app/mirage/ui/Strings.kt`
- Create: `android/app/src/main/res/drawable-nodpi/ic_*.png`（18 个，从 `assets/icon` 复制）
- Test: `android/app/src/test/java/app/mirage/ui/DockIconsTest.kt`

**Interfaces:**
- Produces:
  - `MirageColors`（`blue/gray/dark/status/caption/overlayLabel/overlayBg/waitingBg`）
  - `MirageDimens`（`toolButton=40.dp`、`toolSpacing=10.dp`、`overlayWidth=420.dp`、`overlayRadius=8.dp`、`connectButton=120.dp`）
  - `fun iconRes(action: DockAction, state: DockVisualState): Int`
  - `object MirageStrings`（Spec §7.3 的全部文案）

- [ ] **Step 1: 写失败测试（状态映射）**

```kotlin
@Test fun inputOnUsesActiveIcon()
@Test fun inputOffUsesDisabledIcon()
@Test fun disconnectFirstTapUsesDangerIcon()
@Test fun disconnectIdleUsesDisabledIcon()
@Test fun settingsCollapsedUsesDisabledSettings()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.ui.DockIconsTest'`

- [ ] **Step 3: 复制资源并实现映射**

```bash
mkdir -p android/app/src/main/res/drawable-nodpi
cp assets/icon/close/normal.png android/app/src/main/res/drawable-nodpi/ic_close_normal.png
# 其余 17 个同理，命名与鸿蒙 media 一致
```

`DockIcons` 只做映射，不写布局。

- [ ] **Step 4: 测试通过并提交**

Run: `cd android && ./gradlew :app:testDebugUnitTest`

```bash
git add android/app/src/main/java/app/mirage/ui android/app/src/main/res/drawable-nodpi android/app/src/test/java/app/mirage/ui
git commit -m "feat(android): add harmony-aligned design tokens and toolbar icons"
```

---

### Task 9: 连接页替换（删除设置对话框）

**Files:**
- Create: `android/app/src/main/java/app/mirage/ui/ConnectScreen.kt`
- Create: `android/app/src/main/java/app/mirage/session/ConnectFormState.kt`
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Test: `android/app/src/test/java/app/mirage/session/ConnectFormStateTest.kt`

**Interfaces:**
- Consumes: Task 5 的 `SessionController.ui`、Task 8 的令牌/文案
- Produces:
  - `data class ConnectFormState(host, port, pairLink, mode, busy, status, transportLabel)`
  - `fun validate(host: String, portText: String, fingerprintHex: String, mode: TransportMode): ConnectValidation`
  - `ConnectValidation.Valid(host, port)` / `Invalid(message)`

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun emptyHostIsInvalid()
@Test fun portOutOfRangeIsInvalid()
@Test fun wifiRequiresFingerprint()
@Test fun loopbackWifiDoesNotRequireFingerprint()
@Test fun tcpIgnoresHostAndUses7777()
@Test fun pairingLinkFillsHostPortFingerprint()
@Test fun switchingToWifiDefaultsPortTo7778()
@Test fun switchingToTcpDefaultsPortTo7777()
@Test fun nonLoopbackWifiWithoutFingerprintIsRejected()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.session.ConnectFormStateTest'`

- [ ] **Step 3: 实现页面**

按 Spec §7.2 布局实现 `ConnectScreen`：标题、状态、主机/端口、配对链接、模式行（`导入配对/AUTO/Wi-Fi/TCP/USB/发现 Mac/扫码`）、连接/断开、底部通道标签。ZXing `ScanContract` 迁入此页；mDNS 发现逻辑迁入控制器或页面内的 `remember` 对象，发现成功按指纹规则连接或提示扫码。删除 `SettingsDialog` 与启动自动弹窗。

- [ ] **Step 4: 构建 + 设备验证**

Run: `cd android && ./gradlew :app:assembleDebug`
安装后验证：空地址提示、扫码、粘贴链接、发现 Mac、四种模式切换、连接/断开按钮状态。用 `ui_dump` 确认无旧设置对话框入口。

- [ ] **Step 5: 提交**

```bash
git add android/app/src/main/java/app/mirage
git add android/app/src/test/java/app/mirage/session/ConnectFormStateTest.kt
git commit -m "feat(android): replace the settings dialog with the harmony connect screen"
```

---

### Task 10: 播放页齿轮工具条、Toast 与等待遮罩

**Files:**
- Create: `android/app/src/main/java/app/mirage/ui/StreamScreen.kt`
- Create: `android/app/src/main/java/app/mirage/ui/ControlDock.kt`
- Create: `android/app/src/main/java/app/mirage/session/DockState.kt`
- Modify: `android/app/src/main/java/app/mirage/session/SessionController.kt`
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Test: `android/app/src/test/java/app/mirage/session/DockStateTest.kt`

**Interfaces:**
- Produces:
  - `data class DockState(open: Boolean, debugOn: Boolean, inputOn: Boolean, keyboardOn: Boolean, disconnectArmed: Boolean)`
  - `data class DockIntent(...)`，`fun DockState.apply(intent, nowMs): DockState`
  - `StreamScreen(ui, actions)`：视频、StatsOverlay、ControlDock、等待遮罩

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun disconnectFirstTapArmsAndShowsDanger()
@Test fun disconnectSecondTapWithin3sConfirms()
@Test fun disconnectArmExpiresAfter3s()
@Test fun inputToggleFlipsAndEmitsToast()
@Test fun gearExpandsAndClosesWithoutChangingToggles()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.session.DockStateTest'`

- [ ] **Step 3: 实现工具条**

- `ControlDock`：右下 `bottom 10 / right 6`，收起显示 20dp 齿轮；展开 Column 底部对齐，顺序自下而上 `X`、断开、键盘、输入、调试；纯透明无背景；点击区 40dp。
- 断开两击：第一击 `disconnectArmed=true` 并显示 danger 图标 + Toast `再点一次断开连接`；3s 内第二击 → `controller.disconnect()`；超时通过 500ms 刷新复原。
- 其它按钮切换时更新控制器并 `Toast.makeText` 对应文案（主线程、`!isFinishing` 守卫）。
- 等待遮罩：`ui.overlay != null` 时显示 `#99000000` 全屏，spinner 56dp、文案、倒计时；拦截触摸；倒计时归零由控制器触发 `Stopped`。
- 系统返回键：Streaming/Recovering 时 `OnBackPressedCallback(true)` 吞掉。

- [ ] **Step 4: 构建与设备验证**

Run: `cd android && ./gradlew :app:assembleDebug`
验证：齿轮展开方向、四键顺序、Toast、断开两击、等待遮罩、返回键。

- [ ] **Step 5: 提交**

```bash
git add android/app/src/main/java/app/mirage
git add android/app/src/test/java/app/mirage/session/DockStateTest.kt
git commit -m "feat(android): dock the controls behind a settings button and add confirmation toasts"
```

---

### Task 11: 统计浮层、输入区域与键盘过滤

**Files:**
- Create: `android/app/src/main/java/app/mirage/ui/StatsOverlay.kt`
- Create: `android/app/src/main/java/app/mirage/ui/StatsFormatter.kt`
- Modify: `android/app/src/main/java/app/mirage/input/InputView.kt`
- Modify: `android/app/src/main/java/app/mirage/input/KeyboardBridge.kt`
- Modify: `android/app/src/main/java/app/mirage/ui/StreamScreen.kt`
- Test: `android/app/src/test/java/app/mirage/ui/StatsFormatterTest.kt`
- Test: `android/app/src/test/java/app/mirage/input/KeyFilterTest.kt`

**Interfaces:**
- Produces:
  - `StatsFormatter.lines(snapshot, transportName, width, height): Pair<String, String>`
  - `KeyFilter.shouldHandle(keyCode: Int): Boolean`（Back/音量返回 false，其余 true）

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun formatsP95WhenPresent()
@Test fun omitsP95WhenAbsent()
@Test fun showsDashesWithoutE2eOrRtt()
@Test fun transportIncludesResolution()
@Test fun volumeAndBackAreNotConsumed()
@Test fun navigationKeysAreConsumedWhenKeyboardEnabled()
```

- [ ] **Step 2: 运行确认失败**

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests 'app.mirage.ui.StatsFormatterTest'`

- [ ] **Step 3: 实现**

- `StatsOverlay`：左上、padding 12dp、宽 `min(420dp, 屏宽-24dp)`，两行文案与颜色按 Spec §7.4；`e2e` 不再叠加 decode。
- `InputView`：移除 `excludeRightPx` 右缘整条排除；工具条由 Compose 图层拦截自身触摸。
- `KeyboardBridge`：引入 `KeyFilter`，Back/音量放行，方向/Home/End/PgUp/PgDn 与修饰组合按键盘开启状态处理，避免重复。

- [ ] **Step 4: 构建与设备验证**

Run: `cd android && ./gradlew :app:assembleDebug`
验证：浮层位置/格式/分辨率标签；窄屏不溢出；工具条区域不再整条吞触摸；键盘中文/退格/回车/方向键。

- [ ] **Step 5: 提交**

```bash
git add android/app/src/main/java/app/mirage android/app/src/test/java/app/mirage
git commit -m "feat(android): align the stats overlay and input surface with harmony"
```

---

### Task 12: 持久化补齐、全量验收与文档

**Files:**
- Create: `android/app/src/main/java/app/mirage/session/SettingsCodec.kt`
- Modify: `android/app/src/main/java/app/mirage/session/SessionController.kt`
- Modify: `README.md`、`android/AGENTS.md`（结构段）
- Test: `android/app/src/test/java/app/mirage/session/SettingsCodecTest.kt`

**Interfaces:**
- Produces:
  - `object SettingsCodec { fun decode(map: Map<String, Any?>): PersistedSettings; fun encode(s): Map<String, Any?> }`
  - `PersistedSettings(host, port, fingerprint, deviceIdHex, transportMode, debugOn, inputOn)`

- [ ] **Step 1: 写失败测试**

```kotlin
@Test fun decodesMissingKeysWithDefaults()
@Test fun roundTripsDebugAndInputFlags()
@Test fun invalidTransportModeFallsBackToAuto()
@Test fun pairedAddressIsOnlyWrittenOnWifiSuccess()  // 用纯规则函数 pairWrite(isWifi, success)
```

- [ ] **Step 2: 实现并接线**

`SessionController` 启动读取、变更写入；`debugOn`/`inputOn` 持久化；键盘开关不写；配对地址仅在 Wi-Fi 收到 `SESSION_CONFIG` 时回写。

- [ ] **Step 3: 全量检查**

```bash
cd android && ./gradlew :app:testDebugUnitTest
cd android && ./gradlew :app:lintDebug
cd android && ./gradlew :app:assembleDebug
```

Expected: 测试全绿、lint 无 fatal、构建成功。

- [ ] **Step 4: 真机验收（Spec §8 清单）**

逐项执行并记录结果，特别是：UDP 生效与 e2e/p95、断线 300s 窗口、AUTO 插线回切、旋转、工具条、键盘、输入门控。

- [ ] **Step 5: 更新文档并提交**

更新 `android/AGENTS.md` 的「当前结构」与 `README.md` 的 Android 功能说明（UDP、AUTO、工具条）。过程文档按约定在验收后统一提交。

```bash
git add android/app/src/main/java/app/mirage/session android/app/src/test/java/app/mirage/session
git add android/AGENTS.md README.md
git commit -m "feat(android): persist UI choices and document the aligned client"
```