# Mirage 鸿蒙原生客户端设计

版本：v1.0（2026-11-15）
上位设计：[Mirage 设计文档](2026-11-13-mirage-design.md)（协议、Mac 端、验收标准以该文档为准，本文只写客户端差异）
输入协议：[M5 输入回传设计](2026-11-14-mirage-input-design.md)

---

## 1. 意图与背景

Mirage 目前只有一个客户端：Android APK。鸿蒙设备通过 Anco（卓易通）容器运行该 APK，容器网络栈与生命周期管理导致 Wi-Fi 路径延迟明显高于同协议下的原生实现，容器保活也不可控。

本项目用原生 ArkTS 重写该客户端，**行为与现有 APK 完全对齐**，目的是：

1. 在这台设备（HUAWEI WEB-W00，HarmonyOS 7.0.0.111 / API 26）上获得可日常使用的 Wi-Fi 延迟；
2. 在 GitHub 开源，供其他有「把鸿蒙平板/手机当 Mac 副屏」需求的用户自行构建使用。

Mac 端 Helper 与协议**不改**（除非后续单独立项）。客户端只是协议的另一个实现，靠测试向量与真机联调与两端对齐。

## 2. 目标、非目标、反目标

**目标**

- 功能对齐 APK：USB AOA / Wi-Fi（TCP 明文 + TLS 指纹固定）/ UDP 视频与 NACK / AUTO 降级 / mDNS 发现 / 扫码配对 / 手动地址 / 解码渲染 / 触控、鼠标、键盘、手写笔 / 统计浮层 / 断线重连 / 设置持久化。
- 通道分级：**Wi-Fi 为一等公民**（开源用户主路径，无需 Mac 端桥接进程）；**USB AOA 为实验特性**（依赖 Mac 端 `mirage-aoa` 桥接，厂商 accessory 实现差异未验证）。
- 验收延迟沿用上位设计：Wi-Fi p95 ≤ 100ms、USB p95 ≤ 50ms、60fps 稳定。
- 任何鸿蒙用户拿到源码后，用 DevEco Studio + 自己的华为账号自动签名即可构建安装。
- **前后台语义（v1）**：只承诺前台亮屏可用 + 常亮。切后台不主动断开，但不保证保活；回到前台若已超时则走 `Recovering`。不做 continuous task / 后台任务声明（与现有 APK 的行为一致，APK 也只有 Activity）。

**非目标**

- 不改 Mac 端、不改协议、不新增消息类型。
- 不做多客户端同时连接、不做音频、剪贴板、文件传输。
- 首发不上架 AppGallery（只发 GitHub 源码 + Release 说明）；上架另立项。
- 不承诺未实测机型的表现（见 §3、§13）。

**反目标**

- 为了兼容未验证机型而牺牲已实测路径的延迟。
- 引入账号体系、云端中转或任何遥测。
- 把 Android 的 god-object 结构照搬进来（见 §12）。

## 3. 已实测的平台事实（探针结论，2026-11-15）

这些是设计的地基，不再是假设：

| 项 | 结论 | 影响 |
|---|---|---|
| USB accessory 授权 | `getAccessoryList()` → `hasAccessoryRight()` → `requestAccessoryRight()`（系统弹窗，不可静默）→ `openAccessory()` 返回 fd | 保留轮询；UI 必须提示用户点"允许" |
| USB 热插拔事件 | `usbManager` 无 accessory attach/detach 事件 | AUTO 模式用 1s 轮询代替广播 |
| accessory fd | `/dev/usb_accessory`，非 socket、不可 `fstat`；`@ohos.fileIo` 读写均 EINVAL | 传输必须走原生 `read(2)/write(2)` |
| accessory 读缓冲 | 512 / 1024 / 2048 / 4096 / 16384 成功，65536 返回 EINVAL | 一律用 16KB 缓冲循环读，配合自有拆帧 |
| AOA 全链路 | 写 HELLO 成功后能持续读到 `SESSION_CONFIG` 与视频流 | USB 传输可实现，按实验特性发布 |
| H.264 硬解 | `OH_VideoDecoder_CreateByMime("video/avc")`；60 帧 279ms（≈215fps） | 解码不是瓶颈 |
| 渲染直出 | `OH_VideoDecoder_SetSurface(codec, OHNativeWindow*)` 存在；`OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceId, &window)` 存在 | 用 surface 模式，零拷贝上屏 |
| UDP + AES-256-GCM | `cryptoFramework` AES256\|GCM 往返 0.81ms/次；UDP 自环全收 | UDP 协议可直译 |
| mDNS | `mdns.createDiscoveryService` + `startSearchingMDNS` + `resolveLocalService` 可拿到 host/port 与 TXT（fp/name/v） | 发现功能可直译 |
| TLS 固定 | `TLSSocket` 支持 `skipRemoteValidation` 与 `getRemoteCertificate()` | 握手后校验对端证书 SHA-256，等价 Android 的 pinning |
| 原生 AES-GCM | NDK `CryptoArchitectureKit/crypto_sym_cipher.h` 提供 `AES256\|GCM`（API 12+，动态库 `libohcrypto`） | UDP 收包/解密可下沉 native，避开 ArkTS 加解密开销 |
| 最低 API | USB accessory 相关 API（`hasAccessoryRight` 等）自 API 14 起可用；`mdns` 自 API 10、`TLSSocket`/`getRemoteCertificate` 自 API 9/10 | `compatibleSdkVersion = 12`，USB 在 <14 上运行时降级到 Wi-Fi 并提示 |

## 4. 架构

### 4.1 工程结构

复用现有 `harmony/` 工程（bundleName `app.mirage.harmony`），删除探针页，按以下结构实现：

```
entry/src/main/ets/
├── entryability/EntryAbility.ets        # 窗口、全屏、常亮
├── pages/
│   ├── ConnectPage.ets                  # 连接页 + 设置面板
│   └── StreamPage.ets                   # 全屏播放 + 控制面板 + 统计浮层
├── ui/
│   ├── VideoSurface.ets                 # XComponent 封装，暴露 surfaceId
│   ├── ControlDrawer.ets                # 右侧抽屉（设置/切换连接/键盘/输入开关/调试/断开）
│   └── StatsOverlay.ets
├── core/
│   ├── ClientSession.ets                # 显式状态机（§5）
│   ├── Protocol.ets                     # 帧、HELLO、SESSION_CONFIG、VIDEO、PING
│   ├── UdpProtocol.ets                  # UDP_CONFIG 解析、FEEDBACK/NACK 编码
│   ├── Stats.ets / FeedbackReporter.ets
│   └── Liveness.ets
├── transport/
│   ├── Transport.ets                    # 接口：open/read/write/close
│   ├── TcpTransport.ets
│   ├── TlsTransport.ets                 # 指纹校验
│   ├── UsbTransport.ets                 # 原生 fd 桥
│   └── TransportSelector.ets            # AUTO/USB/WIFI/TCP 选择（纯函数）
├── input/
│   ├── InputMessages.ets                # INPUT / KEY / TEXT / SCROLL 编码
│   ├── GestureMapper.ets                # 手势语义（直译）
│   ├── KeyMapping.ets                   # 鸿蒙 KeyCode → Mac keycode + unicode
│   └── InputController.ets
├── net/
│   ├── MdnsDiscovery.ets
│   └── Pairing.ets                      # mirage://pair 解析
└── settings/SettingsStore.ets           # preferences：host/port/fingerprint/device_id/transportMode

entry/src/main/cpp/
├── video_decoder.cpp/.h                 # AVCodec surface 模式解码器（含 buffer 回退）
├── usb_transport.cpp                    # fd 读写线程 + 帧解码 + threadsafe 回调
├── udp_receiver.cpp/.h                  # UDP 收包 + AES-GCM 解密 + 重组 + NACK（POSIX socket）
├── frame_decoder.cpp/.h                 # [u32 len][u8 type] 拆帧（两端共用）
└── napi_bridge.cpp                      # 导出：startUsb/stopUsb/startUdp/stopUdp/openDecoder/submitVideo/...
```

**为什么 UDP 在 native**：按探针实测，ArkTS `cryptoFramework` 单次 AES-GCM 往返 0.81ms；25Mbps 档约 2600 包/秒，仅解密就要吃掉约一个核，还没算 JS 回调与重组。用 NDK C 接口做收包 + 解密 + 重组，与 USB 共用解码线程，视频字节完全不进 ArkTS。

### 4.2 数据流与线程

```
USB:   usb 读写线程(native) ─拆帧→ VIDEO ─→ 解码器(native, surface) ─→ XComponent surface
                              ├→ SESSION_CONFIG/PING/CTRL/BYE ─napi_threadsafe→ ArkTS ClientSession
                              └→ 每帧元数据(size/flags/ts) ─napi→ ArkTS Stats/Liveness
UDP:   udp 线程(native, POSIX socket) ─AES-GCM─重组─→ VIDEO ─→ 解码器(native)
                              └→ ready/failed/NACK 统计 ─napi→ ArkTS ClientSession
TCP/TLS: TLSSocket/TCPSocket 回调(ArkTS) ─拆帧(ArkTS)─→ submitVideo(ArrayBuffer) ─→ 解码器(native)
                                                        └→ 控制消息直接进 ClientSession
```

- **TCP/TLS 是唯一让视频字节过 ArkTS 的路径**：每帧一次 napi 拷贝（25Mbps ≈ 3MB/s，可接受）。USB 与 UDP（Wi-Fi 主路径）全程在 native。
- ArkTS 侧只有一条控制循环：`ClientSession` 处理协议状态；UI 通过状态字段渲染。
- **权威划分**：ArkTS `ClientSession` 负责 liveness（任何入站事件都算活跃）、统计、e2e、FEEDBACK、关键帧请求；native 只在异常时上报（解码失败、读线程退出、UDP 5s 无响应），并把每帧元数据（frameID、字节数、flags、captureTs、到达时刻）通过 threadsafe function 抛回 ArkTS——60 次/秒的回调量可以忽略。
- 原生日志通过 napi 转回 ArkTS `console.info`，统一前缀 `Mirage`。

### 4.3 关键接口（实现者按此对齐）

```ts
// Transport：TCP/TLS 用 ArkTS socket；USB 由 native 实现后包装
interface Transport {
  open(): Promise<void>;
  write(data: ArrayBuffer): Promise<void>;
  close(): Promise<void>;
}

// native 桥（事件通过注册的回调返回 ArkTS）
startUsb(fd: number): void                          // 启动读线程；内部拆帧、送解码
stopUsb(): void
startUdp(host: string, port: number, key: ArrayBuffer, noncePrefix: ArrayBuffer): void
stopUdp(): void
openDecoder(width: number, height: number, fps: number, surfaceId: string): void
submitVideo(data: ArrayBuffer, flags: number, frameId: number, captureTsMicros: number): void
closeDecoder(): void
setSurface(surfaceId: string): void                 // 旋转/surface 重建
onEvent(cb: (event: NativeEvent) => void): void     // frame/config/closed/udpReady/udpFailed/decoderError

interface NativeEvent {
  kind: 'frame' | 'config' | 'closed' | 'udpReady' | 'udpFailed' | 'decoderError';
  frameId?: number;
  bytes?: number;
  flags?: number;
  captureTsMicros?: number;
  payload?: ArrayBuffer;   // config 时为 SESSION_CONFIG 原始 payload
  reason?: string;
}
```

## 5. 状态机

Android 版的状态散落在 Activity 字段与回调里。鸿蒙版把它抽成显式状态机，这是唯一的结构性"重写"。

**状态**

| 状态 | 含义 | 界面 |
|---|---|---|
| `Idle` | 未连接、无尝试 | 连接页 |
| `Selecting` | 正在按 TransportSelector 决定通道 | 连接页（转圈） |
| `AwaitingUsbAuth` | 已发现 accessory，等系统授权弹窗结果 | 连接页（"等待 USB 授权…"） |
| `Connecting` | 传输已建立，等 SESSION_CONFIG | 连接页（"连接中…"） |
| `Streaming` | 已收到 SESSION_CONFIG，解码渲染中 | 播放页 |
| `Recovering` | 连接断开，退避重连中（≤10 次） | 连接页（"自动重连中…第 n 次"） |
| `Stopped` | 用户主动断开 / 尝试耗尽 | 连接页 |

**事件与转移**

| 事件 | 从 | 到 | 动作 |
|---|---|---|---|
| `connectRequested` | Idle/Stopped | Selecting | 读取设置，`TransportSelector.select` |
| `select(WAIT_USB)` | Selecting | Idle | 状态文案"等待 USB 连接…"；1s 轮询 accessory |
| `select(USB)` 且有权限 | Selecting | Connecting | `openAccessory` → `startUsb` |
| `select(USB)` 无权限 | Selecting | AwaitingUsbAuth | `requestAccessoryRight` |
| `authGranted` | AwaitingUsbAuth | Connecting | 同 USB 连接 |
| `authDenied` | AwaitingUsbAuth | Idle | "USB 权限被拒绝" |
| `wsessionConfig` | Connecting | Streaming | 重建解码器（surface 就绪后）、请求关键帧、开常亮、启动 feedback |
| `closed(reason)` | Connecting/Streaming | Recovering 或 Stopped | 释放解码器与输入；重置输入门控 |
| `retry` | Recovering | Selecting | `connect(isReconnect=true)` |
| `manualDisconnect` | 任意 | Stopped | 停止重连、释放一切 |
| `transportChanged` | Streaming | Selecting | 关闭旧会话，按新模式重连 |
| `rotationChanged` | Streaming | Streaming（重配置） | 重发 HELLO（新宽高/旋转）→ 等新 SESSION_CONFIG → 重建解码器与 surface；不拆连接 |
| `usbDetached`（轮询发现） | Streaming(USB) | Recovering | 若模式为 USB 且无 accessory："USB 已断开，请重新插入" |
| `appPaused` | Streaming | Streaming | 隐藏键盘、`releaseAll` 输入（不断流、不保活）；回前台若 lived 超时则按 `closed("连接无响应")` 处理 |

**规则（与 Android 对齐）**

- 重连退避：`500ms × 2^(n-1)`，上限 5s，最多 10 次；`manualDisconnect` 或 `autoReconnectEnabled=false` 时不重连。
- 每个连接代次（generation）自增；旧代次的回调一律丢弃，防止串台。
- `SESSION_CONFIG` 到达即视为连接成功（重置重连计数）。
- 心跳：每 1s 发 PING；3s 无任何入站帧判定"连接无响应"。
- 收到 `BYE` 立即按断开处理，不尝试复用连接。

## 6. 协议与行为对齐清单

验收时逐行对照。**"直译"表示逻辑与 Android 相同，仅语言差异。**

| Android | 鸿蒙 | 行为 |
|---|---|---|
| `net/Protocol.kt` | `core/Protocol.ets` | 直译：帧编解码、HELLO 32+name、SESSION_CONFIG 11/12 字节、VIDEO 18 字节头、PING u64、单帧上限 8MiB、未知 type 忽略 |
| `net/MirageClient.kt` | `core/ClientSession.ets` | 直译：读循环、PING/PONG 与时钟偏移、e2e 计算、BYE、CTRL 3/4、UDP_CONFIG 接管 |
| `net/UdpProtocol.kt` | `core/UdpProtocol.ets` + `cpp/udp_receiver.cpp` | 头格式与 NACK/FEEDBACK/UDP_CONFIG 编码直译；收包侧在 native |
| `net/UdpVideoReceiver.kt` | `cpp/udp_receiver.cpp` | 直译到 C++：in-flight 3、NACK 间隔 10ms、deadline=max(3RTT,150ms)、1s 丢包窗口、HELLO 每 500ms 重发、5s 无响应报失败 |
| `net/UdpCrypto.kt` | `cpp/udp_receiver.cpp`（NDK `OH_CryptoSymCipher`） | nonce=prefix(4)+seq BE(8)，AAD=16B 头，tag 16B |
| `net/TransportSelector.kt` | `transport/TransportSelector.ets` | 纯函数直译（AUTO 优先 accessory，其次已配置 Wi-Fi，最后 127.0.0.1:7777） |
| `net/TlsStreamConnection.kt` | `transport/TlsTransport.ets` | 连接后取对端证书 DER → SHA-256 → 与二维码指纹常量时间比较 → 不匹配立即断开（未发 HELLO） |
| `net/StreamConnection.kt` | `transport/*.ets` + native | USB 用 native 实现，语义等价 |
| `net/StreamStats.kt` | `core/Stats.ets` | fps/bitrate 每秒窗口，decode/e2e/rtt 最新值 |
| `net/FeedbackReporter.kt` | `core/FeedbackReporter.ets` | 10Hz 上报，字段与 Android 完全一致（含 0 值占位） |
| `net/MdnsDiscovery.kt` | `net/MdnsDiscovery.ets` | 搜索 `_mirage._tcp`，解析 host/port/TXT(fp/name/v)；发现后立即停止搜索 |
| `net/Pairing.kt` | `net/Pairing.ets` | `mirage://pair?v=1&host&port&fp(64hex)&name&id(uuid)` 严格校验，弱条件返回 null |
| `net/InputMessages.kt` | `input/InputMessages.ets` | 直译：指针 32B/样本、KEY 18B、TEXT、SCROLL 20B；非有限浮点拒绝 |
| `input/GestureMapper.kt` | `input/GestureMapper.ets` | 直译状态机：点按、拖动、长按 500ms→右键、双指滚动、捏合→⌘+滚动、笔/橡皮擦、悬停 |
| `input/KeyMapping.kt` | `input/KeyMapping.ets` | 修饰键位映射；鸿蒙 KeyCode → Android 风格 keycode 表 + unicode 推导 |
| `input/InputController.kt` | `input/InputController.ets` | 事件→帧编码；`releaseAll` 同时重置手势状态 |
| `input/KeyboardBridge.kt` + `ImeDispatcher.kt` | `input/KeyboardBridge.ets` | 隐藏 TextInput 接收软键盘文本（onChange 差量→TEXT，退格→KEY），硬件键盘 onKeyEvent→KEY；音量/返回键放行 |
| `MainActivity.kt`（传输选择/重连/授权/代次） | `core/ClientSession.ets` | 语义等价（§5） |
| `MainActivity.kt`（UI 装配） | `pages/*` + `ui/*` | 界面重写，交互对齐 |
| `video/VideoDecoder.kt` | `cpp/video_decoder.cpp` | MediaCodec → AVCodec：surface 优先；关键帧前等 IDR；积压丢帧并请求 IDR；初始化失败退避重试；surface 重建时重建解码器 |

**解码差异（必须记录）**

- Android 的 `KEY_LOW_LATENCY`/厂商键在鸿蒙没有等价物；鸿蒙侧用 surface 模式 + `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY`（若当前 SDK 支持，实现时探测）+ 不设抖动缓冲来达成同等目标。
- 参数集：首帧 Annex-B 中的 SPS/PPS 作为 CSD 传入 `OH_MD_KEY_CODEC_CONFIG`；失败时退回带内参数集并记录日志。
- 解码失败 3 次后放弃并回到 `Recovering`。

## 7. 传输层

### 7.1 选择逻辑

与 Android 相同：`AUTO` 有 accessory → USB；否则已配置 host/port → Wi-Fi；否则 TCP `127.0.0.1:7777`（开发兜底）。`USB`/`WIFI`/`TCP` 为强制模式。USB 无设备时进入等待轮询而不是报错。

### 7.2 USB（实验特性）

- 1s 轮询 `getAccessoryList()`，匹配 `manufacturer === 'Mirage'` 或 `model === 'Mirage Display'`，否则取唯一配件。
- 授权弹窗由系统弹出，UI 文案明确提示"请在系统弹窗中允许"。
- 打开后把 fd 交给 native：16KB 缓冲循环读、`write(2)` 写、native 拆帧。
- 退出：`closeAccessory`，停止读线程；断开后重新进入轮询（= Android 的拔插恢复）。
- 已知限制写进 README：需要 Mac 端运行 `mirage-aoa`；部分厂商 ROM 可能不通。

### 7.3 Wi-Fi

- TCP 明文：仅回环地址（`127.0.0.0/8`、`localhost`、`::1`）允许，对应 `adb reverse`/`hdc fport` 开发路径。
- 非回环：必须 TLS。`TLSSocket.connect({ address, secureOptions: { protocol: TLSv1.2+, }, skipRemoteValidation: true })` → `getRemoteCertificate()` → SHA-256 → 与设置里的指纹比较 → 不一致立即 `close()` 并报"证书指纹不匹配"。
- 指纹来源：扫码 / 粘贴配对链接 / mDNS TXT 中与已存指纹一致时自动连接。
- `TCP_NODELAY`：鸿蒙 TCP socket 通过 `setExtraOptions({ tcpNoDelay: true })` 开启，等价 Android。

### 7.4 UDP

- 收到 `UDP_CONFIG`（flags bit0=1）后，ArkTS 把 `host/port/key/noncePrefix` 交给 native（`startUdp`）；native 自建 POSIX UDP socket（大接收缓冲 ≥4MB），发 HELLO 握手，每 500ms 重试，5s 无响应上报 `udpFailed`，ArkTS 发 CTRL `UDP_FAILED` 回退 TCP。
- 就绪后 native 上报 `udpReady`，ArkTS 发 CTRL `UDP_READY` 并请求关键帧。
- 分片重组、NACK、丢包窗口、AES-256-GCM 解密全部在 native（nonce=prefix(4)+seq BE(8)，AAD=16B 头，tag 16B）；NACK 由 native 直接发回。
- UDP 就绪后忽略 TCP 上的 VIDEO 帧（与 Android 的 UDP 接管语义一致），实现时显式过滤并记录。

## 8. 解码与渲染

- `XComponent({ type: 'surface' })` + `XComponentController.getXComponentSurfaceId()`；surface 变化（旋转、后台恢复）时 `setSurface` 触发解码器重建。
- 解码器建议默认 surface 模式；若 `SetSurface` 或首帧超时，回退 buffer 模式（NV12）并用 `OH_NativeWindow` 手动送帧或走 ArkTS 渲染（回退路径只求可用，不追延迟）。
- 渲染比例：等比适配、居中、黑边；`AspectRatio` 按 SESSION_CONFIG 宽高，`StreamPage` 在收到 config 后更新。
- 常亮：窗口 `keepScreenOn`；全屏与隐藏系统栏由 EntryAbility 设置。
- 统计：`StatsOverlay` 显示 fps / Mbps / drop / decode / e2e / rtt / 连接通道 / 输入状态，数据来自 `Stats`，500ms 刷新。

## 9. 输入

- 采集：XComponent `onTouch`（含 `touches` 多点、`toolType`、压力、倾斜），归一化到画面内容区（去黑边）；边缘手势（右缘 15% 起滑 >40vp）用于呼出控制抽屉，与输入采集互斥（抽屉可见时不转发输入）。
- 手势语义在客户端：与 `GestureMapper` 直译（长按 500ms→右键、双指滚动、捏合→⌘ 滚动、笔/橡皮擦、悬停）。
- 键盘：硬件 `onKeyEvent` → KeyMapping → KEY；软键盘用隐藏 `TextInput`，`onChange` 差量 → TEXT，退格 → KEY，回车 → TEXT "\n"。
- 服务端门控：`CTRL INPUT_ENABLED(3)` / `INPUT_DISABLED(4, reason)` 决定是否允许发送；面板上有输入开关；关闭或页面切走时 `releaseAll`（CTRL 2）。
- 手写笔：`SourceTool`→STYLUS/ERASER，压力与倾斜直传；悬停事件转 HOVER。

## 10. UI 与持久化

- **连接页**：状态文案、连接按钮、设置入口、发现 Mac、扫码配对（best-effort）、手动地址、配对链接粘贴、指纹显示；连接中禁用按钮、显示进度。
- **配对入口分级**：粘贴配对链接是**始终可用**的主路径；扫码用 `@ohos.scan`（Scan Kit），在设备不支持或组件不可用时隐藏按钮并提示用粘贴。扫码是否依赖 AGC 配置待验证（§16），v1 不依赖它。
- **播放页**：全屏视频 + 右侧抽屉（设置、切换连接、键盘、输入开关、调试开关、断开）+ 底部统计浮层 + 右缘把手。
- **持久化**（preferences，键名沿用 Android）：`host`、`port`、`fingerprint`、`device_id`、`transportMode`。
- **HELLO 设备信息**：屏幕像素宽高、DPI、刷新率、旋转、`deviceInfo.productModel`；每次连接与每次旋转后重建（重连流程）。

## 11. 开源工程事项

- **许可证**：MIT（记录为本文档的决定，可改）。
- **仓库卫生**：不提交签名材料（`build-profile.json5` 中的 `signingConfigs` 由 DevEco 自动签名生成、每台机器不同——入库前清空并写入 `.gitignore` 策略）；不提交 `.hvigor/`、`oh_modules/`、`.idea/`、构建产物；探针资源（`probe720.h264`、探针页）删除。
- **README**：项目简介、功能与通道分级（Wi-Fi 一等、USB 实验）、构建步骤（DevEco Studio、SDK 版本、自动签名）、Mac 端依赖（Helper + AOA 桥）、已知限制（未实测机型、USB 厂商差异、扫码需相机权限）、隐私说明（无遥测、设备 ID 本地随机）。
- **文档**：协议文档指向上位设计；本设计随仓库发布。
- **版本号**：`clientVersion=1`（HELLO 字段），与 APK 一致。
- **兼容性声明**：`compatibleSdkVersion = 12`、`targetSdkVersion = 26`；USB 相关 API 自 14 起可用，低版本自动降级到 Wi-Fi 并提示。README 的设备矩阵只列已实测的 WEB-W00。

## 12. 方案取舍（已选）

| 方案 | 内容 | 放弃原因 |
|---|---|---|
| 纯 1:1 移植 | Kotlin 文件逐个翻译，Activity 全局变量照搬 | USB 授权（广播→await）、解码渲染、线程模型无法直译，最终仍要改；会把 1349 行 god-object 搬进 ArkTS |
| 完全重新设计 | 协议侧也重写，按理想模型重新组织 | 丢失 APK 已调稳的行为（BYE 重同步、关键帧门控、UDP 接管、退避参数），风险高 |
| **语义 1:1 + 结构重写（已选）** | 协议/输入/统计直译；传输抽接口；状态机显式化；解码渲染重写 | 保留行为确定性，丢掉 Android 管道债；唯一新设计量在状态机与 native 桥 |

## 13. 里程碑

| 阶段 | 内容 | 退出标准 |
|---|---|---|
| H1 | 工程骨架、Protocol/Stats、TCP + TLS（含指纹校验）、mDNS、粘贴配对（扫码 best-effort）、AVCodec surface 解码上屏 | Wi-Fi 连上 Mac 出画面，60fps，统计可见 |
| H2 | UDP（native 收包 + NDK AES-GCM + 重组/NACK）+ FEEDBACK + 断线重连 + 设置持久化 + 状态机完整 | 弱网下自动回退、断电重连、连续 30min 不断流 |
| H3 | 输入：触控/手势/键盘/笔 + 服务端门控 + 控制抽屉 | 与 Android 端行为逐项对照通过 |
| H4 | USB AOA 传输接入（native fd + 拆帧）+ AUTO 降级 + 热插拔恢复 | 本机 USB 路径 ≤50ms p95，拔插可恢复 |
| H5 | 旋转重配置、开源发布：README、LICENSE、仓库清理、Release 构建说明 | 全新机器按 README 能构建并连上 |

每个阶段结束在 WEB-W00 上真机验收，指标记入 `docs/`。

## 14. 风险

1. **只在一台设备验收**：其他鸿蒙机型（尤其手机、不同芯片）的 AVCodec surface、USB accessory、mDNS 行为未验证。README 必须写明，并对回退路径做保护。
2. **USB 厂商差异**：`/dev/usb_accessory` 读写语义、16KB 上限可能是本机驱动特性；其他设备可能不同，需要运行时容错（读失败 → 明确报错并回退）。
3. **TLS 自签证书与指纹校验**：依赖 `getRemoteCertificate()` 行为在不同 API 版本一致；若某版本拿不到证书，必须拒绝连接而不是降级为不校验。
4. **解码 surface 兼容**：部分设备可能不支持 surface 模式或首帧超时；必须实现 buffer 回退。
5. **系统杀后台/息屏**：v1 只承诺前台亮屏 + 常亮，不做后台保活；README 写明，避免用户预期落空。
6. **mDNS 权限与组播**：鸿蒙可能限制组播；手动地址与二维码是主路径。
7. **入口 UI 差异**：鸿蒙扫码依赖 `@kit.ScanKit`（需相机权限），部分设备无扫码组件；保留粘贴配对链接。

## 15. 留给实现者的决定

- 状态机内部实现（类还是闭包）与事件命名细节。
- 控制抽屉的具体布局、图标与手势阈值（沿用 Android 的 15%/40vp 作为默认）。
- `StatsOverlay` 的排版与刷新频率。
- native 桥中 threadsafe function 的具体回调粒度（逐帧 vs 批事件）。
- 解码器低延迟参数的具体探测方式。
- 回退渲染（buffer 模式）的实现取舍。
- 单元测试组织（协议编解码优先用测试向量对照）。

## 16. 待验证项（实现期）

| # | 项 | 验证方式 |
|---|---|---|
| 1 | `OH_VideoDecoder_SetSurface` 在本机实际渲染成功 | H1 首帧上屏 |
| 2 | `getRemoteCertificate()` 返回 DER 且指纹与 Mac 端一致 | H1 打印 SHA-256 与 QR 指纹对照 |
| 3 | native UDP 收包 + NDK AES-GCM 能否跟上 25Mbps（≈2600 包/秒） | H2 满速实测丢包率与 CPU 占用 |
| 4 | 隐藏 TextInput 的软键盘文本差量行为 | H3 中文输入、退格、回车 |
| 5 | `@ohos.scan` 在 WEB-W00 + 自动签名下是否可直接调起（是否依赖 AGC 配置） | H1/H5 真机点击扫码 |
| 6 | 旋转时同连接重发 HELLO → 新 SESSION_CONFIG 的交互 | H2 前后旋转各 3 次 |
| 7 | 其他机型（手机/不同芯片）兼容性 | 社区反馈或自备设备 |