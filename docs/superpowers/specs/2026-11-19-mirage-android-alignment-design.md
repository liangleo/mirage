# Mirage Android 客户端对齐鸿蒙侧设计

版本：v1.0（2026-11-19）
上位设计：[Mirage 设计文档](2026-11-13-mirage-design.md)（协议与 Mac 端以该文档为准）
对照实现：[鸿蒙原生客户端设计](2026-11-15-mirage-harmony-client-design.md) v1.4

**状态**：已按本文实施（2026-11-19），待验收。本文只描述 Android 侧改动，不改协议、不改 Mac 端。

---

## 1. 意图与背景

Android APK 是 Mirage 最早的客户端，但自原生鸿蒙客户端（H1–H5）落地后，两侧在传输与会话行为上已经分叉：

- 鸿蒙侧已按「按需 AOA（A′）+ AUTO 插线自动切 USB」运行，Android 仍停留在「AUTO 只在连接时选一次通道」。
- 鸿蒙侧 UDP 视频已升级到 24B 头（带采集时间戳）并采用严格顺序交付、首帧后才切 UDP；Android 仍是 16B 头，**与当前 Mac 端线格式不兼容，UDP 实际不可用**。
- 鸿蒙侧把会话抽成了显式状态机，断线时保留播放页并在 5 分钟窗口内重试；Android 状态散落在 `MainActivity` 的 20 多个字段里，断线立即退出播放页，最多重连 10 次后放弃。
- 两侧 UI 已完全不同：鸿蒙是「连接页 + 右下角齿轮工具条 + 左上统计浮层 + Toast」，Android 是「连接页 + 设置对话框 + 右缘侧栏 + 左下六行调试信息」。

本次重构把 Android 拉回与鸿蒙一致的行为与布局。定位是**语义对齐、结构重写**，不是逐行翻译 Kotlin/ArkTS。

## 2. 目标、非目标、反目标

**目标**

- 协议与传输行为对齐：UDP 24B 头与采集时间戳、NACK/顺序交付/回退、`CTRL USB_REQUEST(7)`、AUTO 降级链与插线回切 USB。
- 会话行为对齐：显式状态机、内层退避、外层 5 分钟重连窗口、播放页等待遮罩、永久错误直接停止。
- UI 布局对齐：连接页字段与按钮顺序、播放页右下角齿轮工具条、四键 + X、Toast 文案、统计浮层格式、连接页/等待遮罩配色与尺寸。
- 测试对齐：纯逻辑全部有 JVM 单测；UDP 共享测试向量恢复全绿（当前 2 个失败）。

**非目标**

- 不改协议、不改 Mac 端、不新增消息类型。
- 不把鸿蒙的 native 解码器/UDP 收包器搬过来；Android 继续用 MediaCodec + Kotlin `DatagramSocket`（`android/AGENTS.md` 明确不引入 native 库）。
- 不做多客户端、音频、剪贴板、后台保活。
- 不追求像素级一致；字体、系统栏与 Compose 度量差异接受，布局位置、尺寸语义、状态语义、文案逐字一致。
- 不改 AOA 桥接协议；Android 仍是 accessory 侧，由系统 USB Accessory API 管授权。

**反目标**

- 为了对齐 UI 牺牲 Android 已有的硬解兼容性（厂商低延迟键、CSD 回退）与 ZXing 扫码。
- 保留两套 UI 或两套会话状态机。
- 把 `MainActivity` 的 god-object 原样搬进新类。

## 3. 现状与差距（已核实）

| 领域 | 鸿蒙侧 | Android 现状 | 结论 |
|---|---|---|---|
| UDP 线格式 | 24B 头（含 `captureTsMicros`） | 16B 头（`UdpVideoHeader.SIZE=16`） | Mac 端已发 24B，Android `decode` 抛 `udp length mismatch`，UDP 不可用 |
| UDP 切换 | 收到首个完整帧才发 `UDP_READY`，之后忽略 TCP VIDEO | 收到 HELLO ACK 即发 `UDP_READY`；TCP VIDEO 始终派发 | 重写切换条件与门控 |
| 顺序/重传 | 严格按 frameID 交付，缺片 200ms 放弃并请求 IDR；NACK 3 轮 | 乱序即交付；每片只 NACK 一次；deadline=max(3RTT,150ms) | 重写 `UdpVideoReceiver` 的交付与 NACK 策略 |
| UDP 失败判定 | 30s 无帧 / 出帧后 10s 无数据报 | 5s 无 HELLO 应答 | 对齐阈值 |
| e2e/p95 | UDP 帧带采集时间戳；p95 取最近 300 样本 | UDP 时间戳恒 0；`StreamStats` 无 p95；浮层显示 `e2e+decode` | 补时间戳、p95，浮层改纯 e2e |
| USB_REQUEST | AUTO 走 Wi-Fi 时每 3s 发 `CTRL 7` 并轮询配件 | 无 `USB_REQUEST`，AUTO 不主动回切 | 补 CTRL 码与 AUTO 监听 |
| AUTO 降级 | USB → Wi-Fi（mDNS）→ TCP，失败逐级推进；USB 优先 | 只在连接时选一次，失败原地重试 | 改为阶段式降级与回切 |
| 会话状态 | 显式 reducer + 内层 10 次退避 + 外层 300s 窗口 | Activity 散落字段，10 次后退回连接页 | 抽取状态机与控制器 |
| 旋转 | `windowSizeChange` → 尺寸/旋转变化才重发 HELLO | Activity 重建 → 断开重连 | 加 `configChanges`，会话内重发 HELLO |
| 分辨率变化 | `SESSION_CONFIG` 尺寸变化重开解码器 | 同 surface 不重建解码器 | 补重建条件 |
| 工具条 | 右下齿轮 20vp → 向上展开四键 + X | 右缘 88dp 侧栏 + 18dp 把手 + 右缘滑动 | 整块替换 |
| 提示 | 每次切换 Toast；断开两击（3s） | 无 Toast；断开一键 | 补 Toast 与两击确认 |
| 统计浮层 | 左上；两行 + 传输/分辨率 | 左下；六行；无 p95/分辨率标签 | 重排并统一字段 |
| 持久化 | host/port/fp/device_id/transportMode/debugOn/inputOn | 前五项，无 debugOn/inputOn | 补齐 |
| FEEDBACK | 部分字段有实现 | `droppedFrames/queueDepth/arrivalDelay` 恒 0 | 从解码队列/统计补真实值；Mac 的 `FeedbackController` 会用这三项降码率 |

## 4. 方案取舍

| 方案 | 内容 | 评价 |
|---|---|---|
| A. 增量对齐（已选） | 保留 `MirageClient`/`VideoDecoder`/输入链路；先补协议与 UDP，再抽状态机/控制器，最后替换 UI | 风险最低，每一步可独立测试；不丢 Android 已调稳的硬解与 AOA 行为 |
| B. 按鸿蒙结构整体重写 | 文件一一对应翻译，包括 native 解码/UDP | 平台 API 不同，等于重写；会丢掉厂商解码键与 ZXing；收益低 |
| C. 只对齐 UI | 仅替换 Compose 界面 | 协议仍不兼容，UDP 仍不可用，不满足「对齐所有功能」 |

## 5. 目标结构

```
android/app/src/main/java/app/mirage/
├── MainActivity.kt                 # 薄壳：窗口、生命周期、Compose 宿主
├── session/
│   ├── SessionState.kt             # 状态、事件、UiState 数据类
│   ├── SessionMachine.kt           # 纯 reducer：状态与事件（无副作用）
│   └── SessionController.kt        # 副作用：选路、重连、USB 轮询、HELLO、统计
├── ui/
│   ├── Theme.kt                    # 设计令牌（颜色/尺寸/字号）
│   ├── ConnectScreen.kt            # 连接页（原 DisconnectedScreen + SettingsDialog）
│   ├── StreamScreen.kt             # 播放页（视频 + 齿轮工具条 + 等待遮罩）
│   ├── ControlDock.kt              # 齿轮与四键 + X
│   ├── StatsOverlay.kt             # 统计浮层
│   └── Strings.kt                  # 统一文案常量（与鸿蒙逐字一致）
├── net/                            # 协议、连接、UDP（对齐 24B 头与新语义）
├── input/                          # 手势/键盘（保留，改工具栏排除区）
└── video/                          # MediaCodec（保留，补队列深度/丢帧上报）
```

- `MainActivity` 只保留：`enableEdgeToEdge`、常亮、USB 广播注册、`onConfigurationChanged`、创建/销毁 `SessionController`。
- `SessionController` 持有 `MirageClient`、解码器、USB 状态与重连计时；对 UI 暴露 `StateFlow<SessionUiState>`。
- `SessionMachine` 不接触 Android API，全部可 JVM 单测。

## 6. 行为规格

### 6.1 状态机

状态：`Idle / Selecting / Connecting / Streaming / Recovering / Stopped`。`AwaitingUsbAuth` 不单列状态，`Connecting` 期间通过状态文案「等待 USB 授权…」表达（与鸿蒙实现一致）。

| 事件 | 从 | 到 | 动作 |
|---|---|---|---|
| `Connect` | Idle/Stopped | Selecting | attempts=0，generation+1 |
| `Select(WAIT_USB)` | Selecting | Idle | 文案「等待 USB 连接…」，500ms 轮询配件 |
| `Select(USB/WIFI/TCP)` | Selecting | Connecting | 打开传输，发 HELLO |
| `Config` | Connecting/Streaming | Streaming | attempts=0；重建解码器（尺寸变化时）；请求关键帧；启动 FEEDBACK |
| `Closed(reason)` | Connecting/Streaming/Recovering | Recovering 或 Stopped | attempts+1；≤10 次按 `min(500×2^(n-1), 5000)ms` 退避；>10 → Stopped |
| `Retry` | Recovering | Selecting | 外层每 5s 重试；AUTO 从 USB 重新开始 |
| `Disconnect` | 任意 | Stopped | 停止重连、释放解码器与输入 |
| `TransportChanged` | 任意 | Selecting | 关闭旧会话后按新模式连接 |
| `ScreenChanged(w,h,rotation)` | Streaming | Streaming | 尺寸或旋转变化才重发 HELLO，不主动断流 |
| `AuthDenied/Timeout` | Connecting | Stopped | 永久错误，不重试 |

- **内外两层重连**：`MirageClient` 内的 10 次退避是内层；10 次耗尽后进入外层，播放页不退出，每 5s 重试，总窗口 300s。到期、手动断开或切模式即停止。
- **永久错误**：证书指纹不匹配、USB 授权拒绝/超时 → 直接 `Stopped`，回连接页并显示原因。
- **USB 掉线**：USB 模式 → `Recovering`，文案「USB 已断开，等待重新插入…」，500ms 轮询；重新出现后重连。
- **AUTO 回切 USB**：Wi-Fi/TCP 串流时每 3s 轮询配件并发 `CTRL USB_REQUEST(7)`；配件出现 → 停旧会话 → 等 300ms → 连 USB；连续 3 次失败停止尝试，配件消失后重置。显式 Wi-Fi 不轮询、不发 USB_REQUEST。

### 6.2 AUTO 选择链

每次连接按阶段推进（每次收到 `SESSION_CONFIG` 复位）：

1. stage 0：有配件 → USB；否则有合法 host+port → Wi-Fi；（无地址时）先做一次 mDNS 发现（5s 超时）；
2. stage 1：跳过 USB，走 Wi-Fi；仍失败 → TCP；
3. stage 2：TCP `127.0.0.1:7777`。

mDNS 发现但指纹不一致 → 停止自动连接，提示扫码，绝不自动连。显式 Wi-Fi/TCP/USB 模式只试对应通道。

### 6.3 UDP 视频

- 线格式：24B 大端头 `seq u32 | frameID u32 | fragIndex u16 | fragCount u16 | flags u8 | reserved u8 | payloadLength u16 | captureTsMicros u64`；AAD 为整个 24B 头；nonce = noncePrefix(4) + seq(u64 BE)。
- 启用条件：`UDP_CONFIG` 且非回环 Wi-Fi。
- 握手：每 500ms 发 HELLO，**直到收到首个完整视频帧**；收到 HELLO 不代表就绪。
- 切换：首个完整帧才回调 `onReady` → 发 `CTRL UDP_READY(6)`、请求关键帧、此后忽略 TCP VIDEO。
- 交付：严格按 frameID 递增；头部帧缺片等待，>200ms 仍缺 → 丢弃并请求关键帧；绝不乱序交付。
- NACK：EOF 或更新帧到达 6ms 后发 bitmap，最多 3 轮；服务端缓存最近 8 帧重传。
- 失败：30s 无完整帧，或出帧后 10s 无数据报 → `CTRL UDP_FAILED(5)`，恢复 TCP VIDEO。
- 统计：UDP 帧携带 `captureTsMicros`，与 TCP 共用 e2e/p95 计算。

### 6.4 旋转与分辨率

- Manifest 增加 `configChanges="orientation|screenSize|smallestScreenSize|screenLayout|keyboardHidden|density"`，Activity 不再重建。
- `onConfigurationChanged` → `controller.updateScreen()`；读取新宽高/rotation，与上次不同才重发 HELLO。
- 服务端重建虚拟屏后会短暂断开；按 `Recovering` 自动重连；收到新 `SESSION_CONFIG` 时若宽高变化，释放并重建解码器，重新 aspect-fit。
- `onResume()` 也调用 `updateScreen()`，覆盖息屏/后台期间发生、未收到 `onConfigurationChanged` 的旋转。
- 画面矩阵不旋转：方向由服务端按新尺寸给出。

### 6.5 持久化

SharedPreferences `"mirage"`，键与鸿蒙一致：`host`、`port`、`fingerprint`、`device_id`、`transportMode`、`debugOn`、`inputOn`。

- 传输模式与手填地址启动恢复；调试与输入开关持久化；键盘开关不持久化。
- 配对地址只在 **Wi-Fi 连接成功（收到 SESSION_CONFIG）** 时回写；USB/TCP 成功不覆盖。

## 7. UI 规格

### 7.1 设计令牌（`ui/Theme.kt`）

| Token | 值 |
|---|---|
| `MirageBlue` | `#4A6CF7`（模式选中） |
| `MirageGray` | `#333333`（模式未选） |
| `MirageDark` | `#444444`（断开按钮） |
| `MirageStatus` | `#888888` |
| `MirageCaption` | `#777777` |
| `MirageOverlayLabel` | `#AAAAAA` / `#BBBBBB` |
| `MirageOverlayBg` | `#66000000` |
| `MirageWaitingBg` | `#99000000` |
| 尺寸 | 工具栏图标 20dp（点击区 24dp）、按钮 40dp、点击区 40dp、浮层宽 420dp、圆角 8dp、连接按钮宽 120dp |

420dp 浮层在窄屏上按 `min(420dp, 屏宽-24dp)` 收敛（Android 适配；其余尺寸不变）。

### 7.2 连接页（`ConnectScreen`）

单页，替代原「连接页 + 设置对话框」。**浅色主题**（白底深色字）。竖屏为单列（间距 14dp、内边距 24dp）；高度 < 500dp（横屏手机）自动切换为左右两栏：左栏 标题/状态/主机/配对链接，右栏 模式按钮/连接按钮。顺序：

1. 标题 `Mirage` 28sp Bold。
2. 状态文本 16sp `#888888`。
3. 主机行：标签「主机」宽 56dp；主机输入框占满；端口输入框宽 90dp。
4. 配对链接输入框（占满）。
5. 模式按钮行，14sp，顺序：`导入配对`、`AUTO`、`Wi-Fi`、`TCP`、`USB`、`发现 Mac`、`扫码`。模式按钮选中 `#4A6CF7`，未选 `#333333`；扫码在发现/连接中禁用。
6. 连接行：`连接` 宽 120dp（忙时禁用）；`断开` 宽 120dp，背景 `#444444`（始终可点）。
7. 底部通道标签 12sp `#777777`（如 `Wi-Fi TLS 192.168.1.10:7778`）。

扫码继续用 ZXing 应用内扫（Android 现方案）；`导入配对` 解析第 4 行文本；`发现 Mac` 触发 mDNS，指纹一致才自动连接。
原「启动时无地址自动弹设置」改为：状态提示「请填写主机与端口」，页面本身即可输入，不弹窗。
切换模式时端口默认值跟随通道：Wi-Fi → 7778，TCP → 7777，AUTO 恢复已配对地址（用户手填值保留）。

**安全取舍**：鸿蒙在 Wi-Fi 指纹缺失时会退回明文 TCP；Android **不跟随**，非回环 Wi-Fi 仍要求 64 位指纹，否则提示扫码配对。这是有意保留的更严格行为。

### 7.3 播放页（`StreamScreen`）

全屏黑底，`Stack`：

- `VideoView` 居中黑边等比适配。
- 输入层仅在内容区有效；工具条按钮只拦截自身区域（移除原右缘 24dp 排除条）。
- 输入被禁时用 Toast（不保留顶部原因条）。
- 调试开启时左上 `StatsOverlay`，外层 padding 12dp，`HitTestMode` 等价为不拦截触摸。
- 右下齿轮工具条（纯透明无底色），`bottom 10dp / right 6dp`：
  - 收起：`ic_settings_disabled` 20dp，放在 40dp 点击区。
  - 展开：Column 底部对齐，自下而上为 `X`、断开、键盘、输入、调试；每个 40dp，间距 4dp。因为列底对齐，展开天然向上生长。
  - 图标状态：调试/输入/键盘 = 白（开）/ 灰（关）；断开默认灰，第一次点击变红，3s 内再点才真正断开，超时自动复原。
  - 无文字标签。
- 等待遮罩（Recovering）：全屏 `#99000000`，居中 Loading 56dp 白色；文案 16sp 白色；`等待重连 ${remainSec}s` 14sp `#AAAAAA`；拦截触摸；倒计时到 0 回连接页。
- 无返回按钮；Streaming 时拦截系统返回键，退出只能走工具条。
- Toast 文案与时机（与鸿蒙逐字一致）：`触控已开启` / `触控已关闭` / `键盘已打开` / `键盘已关闭` / `调试信息已开启` / `调试信息已关闭` / `再点一次断开连接` / `服务端未开放输入` / 门禁 reason（空则 `输入已暂停`）。

### 7.4 统计浮层（`StatsOverlay`）

500ms 刷新，两行：

- 行 1：`${fps} fps · ${bitrate.toFixed(1)} Mbps · drop ${dropped}[ · p95 ${n}ms]`；右侧 `${transportName} ${width}×${height}`。
- 行 2：`decode ${x.toFixed(1)}ms · e2e ${e2e|--} · RTT ${rtt|--} · ${codec}`。

容器宽 420dp（窄屏收敛），内边距左右 14dp/上下 8dp，背景 `#66000000`，圆角 8dp；行 1 13sp 白，右侧 12sp `#AAAAAA`，行 2 13sp `#BBBBBB`。通道名：`USB`、`Wi-Fi`、`Wi-Fi UDP`、`TCP`。

### 7.5 图标与键盘

- 工具栏图标为矢量图（由设计稿 SVG 提取）：Android `res/drawable/ic_<action>_<state>.xml`，鸿蒙 `media/ic_<action>_<state>.svg`。24×24、stroke 1.8；显示 20dp、点击区 24dp、间距 4dp。
- 因项目已有统一图标资产，这里是有意偏离 `android/AGENTS.md` 的「只用 material-icons-core」；新按钮全部使用这套 PNG，避免两侧观感漂移。
- 键盘桥保留现有实现；补导航键/修饰键过滤（Back/音量放行，方向/Home/End/PgUp/PgDn 与 Cmd/Alt 组合交给桥，避免页面与 IME 重复处理）。

## 8. 测试与验收

**JVM 单测（必须全绿）**

- 协议/UDP：共享向量（24B 头、NACK、FEEDBACK、UDP_CONFIG）、captureTs 往返、e2e/p95。
- UDP 接收器：顺序交付、乱序缓存、200ms 放弃+关键帧、NACK 3 轮、30s/10s 失败、首帧前不 ready。
- 会话：状态机全部转移、内层退避、外层窗口、永久错误、USB 断线、AUTO 阶段推进、回切 USB 3 次上限。
- 选路/配对/mDNS：现有测试保留并补 AUTO 阶段。
- 输入：现有手势/键映射测试保留。

**构建与静态检查**

```bash
cd android && ./gradlew :app:testDebugUnitTest
cd android && ./gradlew :app:lintDebug   # 无 fatal
cd android && ./gradlew :app:assembleDebug
```

（本机 `java` 不在 PATH 时需显式 `JAVA_HOME=~/Library/Java/JavaVirtualMachines/corretto-17.0.18/Contents/Home`。）

**真机验收清单**

1. Wi-Fi：连接 → 出画面 → UDP 生效（浮层显示 `Wi-Fi UDP WxH`，e2e/p95 有值）。
2. 断网 10s：播放页保留、遮罩倒计时、恢复后自动续流；300s 到期回连接页。
3. AUTO：Wi-Fi 串流时插线 → 自动切 USB（日志有 `USB_REQUEST`，浮层变 `USB`）；拔线 → 回 Wi-Fi。
4. 旋转：横竖各 3 次，画面跟随、不退出播放页。
5. 工具条：齿轮展开/收起、四个开关 Toast、断开两击 3s、调试浮层格式与位置。
6. 连接页：主机/端口/配对链接/模式/发现/扫码/导入配对；错误文案。
7. 键盘：软键盘中文、退格、回车；硬件键盘；Back/音量不被吞。
8. 输入门控：服务端禁用时 Toast 与释放按键。
9. 共享测试向量全绿，lint 无 fatal。

## 9. 风险

1. **UDP 重写引入回归**：现有 Kotlin 接收器有 NACK/乱序测试可复用；先写测试再改，保留失败回退 TCP 的硬保险。
2. **`configChanges` 与 Surface 生命周期**：避免 Activity 重建后需验证 Compose 重排与 Surface 不重建；若个别机型 Surface 重建，解码器重建路径已存在。
3. **AUTO 回切 USB 与单客户端限制**：必须先停旧会话再连 USB，等待 300ms 释放端口；连续失败计数防止来回抖动。
4. **Toast 在后台/无窗口时抛异常**：统一切主线程并判 `isFinishing`。
5. **UI 对齐与 `android/AGENTS.md` 的令牌约束**：所有新颜色/尺寸集中在 `Theme.kt`，不散落硬编码。
6. **420dp 浮层在手机窄屏溢出**：按屏宽收敛，语义不变。
7. **没有 Android 真机时**：UI 可在模拟器验收，但 UDP/性能/AOA 必须真机；无法验收的部分在交付说明中明确写出。

## 10. 待评审决定

1. 连接页改为单页并删除设置对话框（本文已按此设计）。
2. 播放页拦截返回键，只允许工具条断开（本文已按此设计）。
3. 统计浮层 420dp 在窄屏收敛（本文已按此设计）。
4. 图标改用 `assets/icon` PNG（有意偏离 AGENTS 的 Material 图标约定）。
5. 非回环 Wi-Fi 继续强制指纹，不跟随鸿蒙的「无指纹退回明文 TCP」。切换模式时端口默认 Wi-Fi 7778 / TCP 7777。

另记：鸿蒙侧 HELLO 的 `features=0x70` 与协议文档（bit0 笔/bit1 压感/bit2 倾斜/bit3 悬停）不一致，且 Mac 端未消费该字段，因此 Android 保持 `features=0`，不复制这个值；如需能力协商，另立协议项修正两端。
## 11. 实施记录（2026-11-19）

- **已完成**：工具条图标改为 SVG 矢量（normal `#6B7280`；input/keyboard/settings active `#38BDF8`；debug `#FBBF24`；disconnect `#F87171`；close hover `#E2E8F0`；显示 20dp、点击区 24dp、间距 4dp；`gear` 更名 `settings`，断开两击使用 active）；UDP 24B 头/采集时间戳/顺序交付/NACK/回退；`CTRL USB_REQUEST(7)`；AUTO 阶段链与插线回切（3 次失败停手）；显式 `SessionMachine`（作为重连计数与退避的权威）；旋转重发 HELLO 与解码器重建；单页连接页；右下齿轮工具条（20dp 齿轮、40dp 四键 + X、白/灰/红语义、Toast、两击断开 3s）；统计浮层（两行 + 通道/分辨率 + p95）；输入区域与键盘过滤；配置持久化。
- **验证**：Android JVM 单测 144/144；`:app:lintDebug` 无 Error；`:app:assembleDebug` 成功；模拟器（mirage_test）配合 `tools/mock_mac.py` 实测连接页、播放页、工具条展开、Toast、两击断开、统计浮层与 60fps 测试图。
- **真机验收（vivo PD2309，2026-11-19）**：
  - Wi‑Fi TLS + UDP：连上后浮层 `Wi‑Fi UDP 2800×1260`，e2e 18–137ms、p95 11–170ms、RTT 24–48ms、硬解，静态画面 0–1fps（无脏矩形属预期）；Mac 侧确认 `udp peer ready` / `udp ready`。
  - AUTO 插线回切：点 AUTO 后自动 `CTRL USB_REQUEST` → 桥恢复 → 浮层变 `USB 2800×1260`，e2e 9ms、p95 11ms、RTT 3ms。
  - 修复过程中发现并处理：UDP 帧原先未计算 e2e（补 `E2e.compute` 并接入 UDP/TCP 两条路径）；AUTO 从 USB 掉线时阶段会被推进到 TCP，改为固定回退到 Wi‑Fi 阶段。
  - 暂未验证（需用户配合物理动作）：旋转（设备锁屏）、拔线后的 USB→Wi‑Fi 回退观感、触控注入。
- **有意偏离**：连接页模式按钮在窄屏拆成两行（导入/发现/扫码 + 四个模式），避免横向滚动藏按钮；其余尺寸与文案按 §7。
- **真机追加验证（2026-11-19）**：浅色连接页与横屏两栏布局已实机确认；旋转时客户端日志确认 `onConfigurationChanged → HELLO 新宽高 → 解码器按新分辨率重建`，Mac 端 `extend_resize` 生效；AUTO 从 USB 掉线回到 Wi‑Fi UDP 已由用户确认；静止画面 UDP 不因 10s 无数据报误回退（TCP 控制通道活跃即保活）。
- **旋转最终方案**：`onConfigurationChanged`/`onResume` 检测尺寸变化 → 发送新 HELLO → **锁定当前通道强制重连**（避免 AUTO 在重连时切到 AOA，旧 HELLO 导致分辨率不更新）；真机确认横竖切换后分辨率随之变化（`2800×1260 ↔ 1260×2800`）。
- **仍未复现确认**：物理插回 USB 后自动回切（已补 attach→300ms `switchToUsb` 与阶段复位，待用户终验）；UDP 弱网丢包注入。
