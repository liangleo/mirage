# Mirage 鸿蒙原生客户端设计

版本：v1.2（2026-11-17，实现收尾同步：AUTO 回切 USB、统一重连、FEEDBACK、Mac 服务模型；H2 UDP 仍待实现）
上位设计：[Mirage 设计文档](2026-11-13-mirage-design.md)（协议、Mac 端、验收标准以该文档为准，本文只写客户端差异）
输入协议：[M5 输入回传设计](2026-11-14-mirage-input-design.md)

**实现状态**：H1（Wi-Fi TCP/TLS 出画面）、H3（输入与控制工具条）、H4（USB AOA + AUTO 降级）已落地；FEEDBACK（10Hz 接收状态上报）已实现并驱动 Mac 端自适应码率；H2 的 UDP 视频仍未实现——客户端解析到 `UDP_CONFIG` 后忽略，Mac 端在收不到 UDP 握手前继续走 TCP。本轮另有三处平台经验固化：TLS 固定 1.2、AUTO 插线自动回切 USB、Mac 服务开启即同时提供 USB + Wi-Fi（运行中经回环控制通道启停，不重启捕获）。正文已按实到代码修订。

---

## 1. 意图与背景

Mirage 目前只有一个客户端：Android APK。鸿蒙设备通过 Anco（卓易通）容器运行该 APK，容器网络栈与生命周期管理导致 Wi-Fi 路径延迟明显高于同协议下的原生实现，容器保活也不可控。

本项目用原生 ArkTS 重写该客户端，**行为与现有 APK 完全对齐**，目的是：

1. 在这台设备（HUAWEI WEB-W00，HarmonyOS 7.0.0.111 / API 26）上获得可日常使用的 Wi-Fi 延迟；
2. 在 GitHub 开源，供其他有「把鸿蒙平板/手机当 Mac 副屏」需求的用户自行构建使用。

Mac 端 Helper 与协议**不改**（除非后续单独立项）。实现期唯一例外是 Mac 端录屏权限的一次性预检（缺失时 `exit(4)` 并在菜单栏给出设置路径），属阻塞性修复，不涉及协议。客户端只是协议的另一个实现，靠测试向量与真机联调与两端对齐。

## 2. 目标、非目标、反目标

**目标**

- 功能对齐 APK：USB AOA / Wi-Fi（TCP 明文 + TLS 指纹固定）/ UDP 视频与 NACK（H2，待实现）/ AUTO 降级 / mDNS 发现 / 扫码配对 / 手动地址 / 解码渲染 / 触控、鼠标、键盘、手写笔 / 统计浮层 / 断线重连 / 设置持久化。
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
| 最低 API | USB accessory 相关 API（`hasAccessoryRight` 等）自 API 14 起可用；`mdns` 自 API 10、`TLSSocket`/`getRemoteCertificate` 自 API 9/10 | 暂定 `compatibleSdkVersion = 26`（H1 验收用 26；H5 再评估下探到 12），USB 在 <14 上运行时降级到 Wi-Fi 并提示 |

## 4. 架构

### 4.1 工程结构

复用现有 `harmony/` 工程（bundleName `app.mirage.harmony`），删除探针页，按以下结构实现：

```
entry/src/main/ets/
├── entryability/EntryAbility.ets        # 窗口、全屏、常亮
├── pages/
│   ├── ConnectPage.ets                  # 连接页 + 设置面板
│   └── StreamPage.ets                   # 全屏视频 + 右下角工具条 + 统计浮层
├── ui/
│   ├── VideoSurface.ets                 # XComponent 封装，暴露 surfaceId
│   ├── InputOverlay.ets                 # 触控采集与本地触点提示
│   ├── KeyboardDock.ets                 # 软键盘桥
│   └── StatsOverlay.ets
├── core/
│   ├── ClientSession.ets                # 显式状态机运行时（§5）
│   ├── SessionMachine.ets               # 纯 reducer：状态与事件
│   ├── Runtime.ets                      # 跨页共享的单会话引用
│   ├── Protocol.ets                     # 帧、FrameDecoder、HELLO、SESSION_CONFIG、VIDEO、PING
│   ├── InputProtocol.ets / InputGate.ets # INPUT/KEY/TEXT/SCROLL 编码、服务端门控
│   └── Stats.ets
├── transport/
│   ├── Transport.ets                    # 接口：open/read/write/close
│   ├── TcpTransport.ets
│   ├── TlsTransport.ets                 # 指纹校验
│   ├── UsbDevice.ets                    # 配件匹配纯逻辑
│   ├── UsbTransport.ets                 # 授权 + 原生 fd 桥包装
│   └── TransportSelector.ets            # AUTO/USB/WIFI/TCP 选择（纯函数）
├── input/
│   ├── GestureMapper.ets                # 手势语义（直译）
│   ├── KeyMapping.ets                   # 鸿蒙 KeyCode → Mac keycode + unicode
│   ├── ImeBridge.ets                    # 软键盘文本差量
│   └── InputGeometry.ets                # 触点到画面坐标归一化
├── net/
│   ├── MdnsDiscovery.ets
│   └── Pairing.ets                      # mirage://pair 解析
└── settings/SettingsStore.ets           # preferences：host/port/fingerprint/device_id/transportMode

entry/src/main/cpp/
├── video_decoder.cpp/.h                 # AVCodec surface 模式解码器（含 buffer 回退）
├── usb_transport.cpp/.h                 # fd 读取线程 + threadsafe 回调 + O_NONBLOCK 写
└── bridge.cpp                           # 导出：startUsb/stopUsb/usbWrite/openDecoder/submitVideo/...
```

H2 的 UDP 视频未实现，故没有 `core/UdpProtocol.ets`、`cpp/udp_receiver.cpp`、`cpp/frame_decoder.cpp`；拆帧统一在 ArkTS `Protocol.ets` 的 `FrameDecoder`。FEEDBACK 已实现：28 字节编码在 `Protocol.ets`，10Hz 上报在 `ClientSession.ets`（`FEEDBACK_INTERVAL_MS = 100`）。

### 4.2 数据流与线程

```
USB:   usb 读线程(native) ─16KB 块─napi_threadsafe→ ArkTS FrameDecoder ─→ submitVideo ─→ 解码器(native, surface) ─→ XComponent
TCP/TLS: TLSSocket/TCPSocket 回调(ArkTS) ─拆帧(ArkTS)─→ submitVideo(ArrayBuffer) ─→ 解码器(native)
```

- **USB 只接管字节通道**：native 读线程把原始 16KB 块抛回 ArkTS，拆帧、控制消息、统计、心跳全部复用 TCP 路径的 `ClientSession`/`FrameDecoder`。这是对原设计「USB 全程 native」的有意偏离——代价是每帧一次 napi 拷贝（与 TCP 路径同量级，25Mbps ≈ 3MB/s），换来不重复实现协议与统计。真机 USB p95 若超过 50ms，再按 native 分帧直送解码器升级。
- ArkTS 侧只有一条控制循环：`ClientSession` 处理协议状态；UI 通过状态字段渲染。
- **权威划分**：ArkTS `ClientSession` 负责 liveness（任何入站事件都算活跃）、统计、e2e、关键帧请求、输入门控；native 负责解码与 USB 字节读写，只在异常时上报（解码失败、读线程退出）。
- 原生日志通过 napi 转回 ArkTS `hilog`，统一前缀 `Mirage`。

### 4.3 关键接口（实现者按此对齐）

```ts
// Transport：TCP/TLS 用 ArkTS socket；USB 由 native 读字节后交给 ArkTS 拆帧
interface Transport {
  open(): Promise<void>;
  write(data: ArrayBuffer): Promise<void>;
  close(): Promise<void>;
}

// native 桥（libmirage.so）
openDecoder(width: number, height: number, fps: number, surfaceId: string,
            cb: (ok: boolean) => void): void
submitVideo(data: ArrayBuffer, flags: number, frameId: number,
            captureTsMicros: number): number       // -1 = 解码器未就绪/输入被拒
closeDecoder(): void
onEvent(cb: (event: DecoderEvent) => void): void   // kind: ready/closed/error
startUsb(fd: number, cb: (kind: string, data: ArrayBuffer | null) => void): boolean
stopUsb(): void
usbWrite(data: Uint8Array): number                 // -1 = 未打开/写失败
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

**实现说明**：`AwaitingUsbAuth` 未接入 reducer。授权是 `UsbTransport.open()` 内的一次 `await`（60s 超时兜底），期间状态保持 `Connecting`，只通过 `onAuthPending` 回调把文案改成「等待 USB 授权…」。区分独立状态收益仅为文案，等真机确认需要时再扩状态机。

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

- 重连退避：Wi-Fi/TCP 先由会话内部按 `500ms × 2^(n-1)`（上限 5s、最多 10 次）重试；耗尽后由连接页接管，每 5 秒重试一次，窗口 5 分钟（AUTO 每次重试从 USB 优先开始）。窗口到期、用户手动断开或切模式即停止。
- 断线期间不退回连接页：播放页保留，`Runtime.onWaiting(message, deadline)` 驱动菊花 + 倒计时；永久错误（指纹不匹配、USB 授权拒绝/超时）直接 `Runtime.onClosed` 退栈。
- 每个连接代次（generation）自增；旧代次的回调一律丢弃，防止串台。
- `SESSION_CONFIG` 到达即视为连接成功（重置重连计数）。
- 心跳：每 1s 发 PING；3s 无任何入站帧判定"连接无响应"。
- 收到 `BYE` 立即按断开处理，不尝试复用连接。

## 6. 协议与行为对齐清单

验收时逐行对照。**"直译"表示逻辑与 Android 相同，仅语言差异。**

| Android | 鸿蒙 | 行为 |
|---|---|---|
| `net/Protocol.kt` | `core/Protocol.ets` | 直译：帧编解码、HELLO 32+name、SESSION_CONFIG 11/12 字节、VIDEO 18 字节头、PING u64、单帧上限 8MiB、未知 type 忽略 |
| `net/MirageClient.kt` | `core/ClientSession.ets` | 直译：读循环、PING/PONG 与时钟偏移、e2e 计算、BYE、CTRL 3/4、`UDP_CONFIG` 忽略（H2 未实现） |
| `net/UdpProtocol.kt` / `net/UdpVideoReceiver.kt` / `net/UdpCrypto.kt` | — | **未实现（H2 待立计划）**：客户端忽略 `UDP_CONFIG`；等服务端收到 UDP 握手前视频继续走 TCP |
| `net/FeedbackReporter.kt` | `core/Protocol.ets` + `core/ClientSession.ets` | 10Hz 上报 28 字节反馈（fps/解码/丢帧/队列/RTT/码率/到达延迟），驱动 Mac 端码率自适应 |
| `net/TransportSelector.kt` | `transport/TransportSelector.ets` | 纯函数直译（AUTO 优先 accessory，其次已配置 Wi-Fi，最后 127.0.0.1:7777） |
| `net/TlsStreamConnection.kt` | `transport/TlsTransport.ets` | 连接后取对端证书 DER → SHA-256 → 与二维码指纹常量时间比较 → 不匹配立即断开（未发 HELLO） |
| `net/StreamConnection.kt` | `transport/*.ets` + native | USB 由 native 读字节、ArkTS 拆帧（§4.2） |
| `net/StreamStats.kt` | `core/Stats.ets` | fps/bitrate 每秒窗口，decode/e2e/rtt 最新值 |
| `net/MdnsDiscovery.kt` | `net/MdnsDiscovery.ets` | 搜索 `_mirage._tcp`，解析 host/port/TXT(fp/name/v)；发现后立即停止搜索 |
| `net/Pairing.kt` | `net/Pairing.ets` | `mirage://pair?v=1&host&port&fp(64hex)&name&id(uuid)` 严格校验，弱条件返回 null |
| `net/InputMessages.kt` | `core/InputProtocol.ets` | 直译：指针 32B/样本、KEY 18B、TEXT、SCROLL 20B；非有限浮点拒绝 |
| `input/GestureMapper.kt` | `input/GestureMapper.ets` | 直译状态机：点按、拖动、长按 500ms→右键、双指滚动、捏合→⌘+滚动、笔/橡皮擦、悬停 |
| `input/KeyMapping.kt` | `input/KeyMapping.ets` | 修饰键位映射；鸿蒙 KeyCode → Android 风格 keycode 表 + unicode 推导 |
| `input/InputController.kt` | `core/InputGate.ets` + `pages/StreamPage.ets` | 事件→帧编码；`releaseAll` 同时重置手势状态 |
| `input/KeyboardBridge.kt` + `ImeDispatcher.kt` | `input/ImeBridge.ets` + `ui/KeyboardDock.ets` | 隐藏 TextInput 接收软键盘文本（onChange 差量→TEXT，退格→KEY），硬件键盘 onKeyEvent→KEY；音量/返回键放行 |
| `MainActivity.kt`（传输选择/重连/授权/代次） | `core/ClientSession.ets` | 语义等价（§5） |
| `MainActivity.kt`（UI 装配） | `pages/*` + `ui/*` | 界面重写，交互对齐 |
| `video/VideoDecoder.kt` | `cpp/video_decoder.cpp` | MediaCodec → AVCodec：surface 优先；关键帧前等 IDR；积压丢帧并请求 IDR；初始化失败退避重试；surface 重建时重建解码器 |

**解码差异（必须记录）**

- Android 的 `KEY_LOW_LATENCY`/厂商键在鸿蒙没有等价物；鸿蒙侧用 surface 模式 + `OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY`（若当前 SDK 支持，实现时探测）+ 不设抖动缓冲来达成同等目标。
- 参数集：首帧 Annex-B 中的 SPS/PPS 作为 CSD 传入 `OH_MD_KEY_CODEC_CONFIG`；失败时退回带内参数集并记录日志。
- 解码失败 3 次后放弃并回到 `Recovering`。

## 7. 传输层

### 7.1 选择逻辑

`USB`/`WIFI`/`TCP` 为强制模式。USB 无设备时进入等待轮询而不是报错。

`AUTO` 是逐级降级链，每级只试一次（收到 `SESSION_CONFIG` 或用户手动连接后复位）：

1. 有 Mirage accessory → USB；
2. 否则已有配对/手填的 host+port → Wi-Fi TLS（指纹沿用已保存值）；
3. 否则做一次 mDNS 发现（5s 超时）；发现且指纹一致 → Wi-Fi TLS；发现但指纹不一致 → 停下提示扫码，绝不自动连接；
4. 都没有 → TCP `127.0.0.1:7777`（开发兜底）。

连接失败时按当前通道推进到下一级：USB 失败 → 跳过 USB 重试（Wi-Fi/TCP）；Wi-Fi 失败 → TCP。

**断线与重连（各模式统一）**：不再立即退回连接页。播放页保留最后一帧，叠加菊花 + 倒计时遮罩，窗口 5 分钟、每 5 秒重试一次；期限到才回连接页。AUTO 的重试从 USB 优先开始（数据线可用就直接连 USB）；AUTO 在 Wi-Fi/TCP 上串流时每 3 秒轮询配件，配件出现即停旧会话、切回 USB，连续 3 次切换失败则停手（配件消失后重置）。显式 Wi-Fi 模式不会切 USB。永久错误（证书指纹不匹配、USB 授权被拒绝/超时）直接停止并回连接页。

Mac 端配合：AOA 桥常驻等待 USB 设备（无设备不再退出），这样插线后配件一定出现；helper 与开关均见 §7.5。

### 7.2 USB（实验特性）

- 1s 轮询 `getAccessoryList()`，匹配 `manufacturer === 'Mirage'` 或 `product === 'Mirage Display'`，否则取唯一配件。
- 授权弹窗由系统弹出，UI 文案明确提示"请在系统弹窗中允许"；`requestAccessoryRight` 60s 超时兜底。拒绝或超时 → 停止并报原因，不重新轮询（否则会反复弹窗）。
- 打开后把 fd 交给 native 读线程：设 `O_NONBLOCK`，`poll(POLLIN, 500ms)` + 16KB `read(2)`，数据块经 threadsafe function 抛回 ArkTS 拆帧。
- 写方向：`usbWrite` 循环写完；遇 `EAGAIN` 用 `poll(POLLOUT, 500ms)` 等待，超时返回 -1。写入失败按瞬态处理（Mac 桥可能正在重启），进入等待轮询。
- 退出：`closeAccessory`，停止读线程；仅在真实掉线（`USB 已断开` / `未发现 USB 设备` / `USB 写入失败`）时重新进入轮询。USB 重连退避上限压到 1s。
- 已知限制写进 README：需要 Mac 端运行 `mirage-aoa`；AOA 模式会隐藏 hdc，调试时需拔插数据线恢复。

### 7.3 Wi-Fi

- TCP 明文：仅回环地址（`127.0.0.0/8`、`localhost`、`::1`）允许，对应 `adb reverse`/`hdc fport` 开发路径。
- 非回环：必须 TLS。`TLSSocket.connect({ address, secureOptions: { protocols: [TLSv1.2] }, skipRemoteValidation: true })` → `getRemoteCertificate()` → SHA-256 → 与设置里的指纹比较 → 不一致立即 `close()` 并报"证书指纹不匹配"。
- **固定 TLS 1.2**：HarmonyOS 的 TLS 1.3 收包路径在一个 16KB 记录之后会停顿数秒，大帧（关键帧）因此要几秒才能收完；固定 1.2 实测 16KB 记录 33ms 内到齐、e2e 回到 6–42ms。服务端最低 1.2，强制 1.2 不损失兼容性。
- 指纹来源：扫码 / 粘贴配对链接 / mDNS TXT 中与已存指纹一致时自动连接。
- `TCP_NODELAY`：鸿蒙 TCP socket 通过 `setExtraOptions({ tcpNoDelay: true })` 开启，等价 Android。

### 7.4 UDP（未实现，H2 待立计划）

- 客户端目前解析到 `UDP_CONFIG` 后直接忽略；Mac 端在收到 UDP 握手前继续发 TCP 视频，Wi-Fi 出画面不受影响。
- H2 若启动，按原设计：收到 `UDP_CONFIG` 后把 `host/port/key/noncePrefix` 交给 native，POSIX UDP socket + AES-256-GCM 解密 + 重组 + NACK 全部在 native（ArkTS 单次 AES-GCM 往返 0.81ms，25Mbps 档约 2600 包/秒，放在 JS 会吃掉约一个核），就绪后发 `UDP_READY` 并忽略 TCP 视频。

### 7.5 Mac 端服务模型（本轮落地）

- 一个 helper 进程同时提供：`127.0.0.1:7777` 明文（AOA 桥用）+ `0.0.0.0:7778` TLS + mDNS `_mirage._tcp`；helper 只接受一个客户端。
- 菜单只保留「开启/关闭服务」，不再有独立的 USB/Wi-Fi 开关：开启服务 = 拉起 helper + 开 Wi-Fi + 启动 AOA 桥；关闭服务 = 停桥 + 停 helper。
- 运行中开关 Wi-Fi 走回环控制通道 `127.0.0.1:7779`（`wifi on|off|status`，一行命令一行应答），不重启捕获、虚拟显示器或 USB 会话。带 `--control-port` 启动的 helper 在就绪时直接开 Wi-Fi，避免菜单在启动窗口期抢时序失败。
- AOA 桥常驻等待设备（无设备不退出）；服务开启时线没插也能在插入后自动切 AOA。
- 服务停止后再开启必须恢复 USB：菜单记录刚被终止的 helper PID，`start()` 会先等端口释放再拉起新 helper，不再把正在退出的旧进程当成「已有 helper」接管；接管已有/外部 helper 时同样会启动 AOA 桥（服务 = 双通道）。
- macOS 菜单栏「停止共享」会停掉 `SCStream`：helper 通过 `SCStreamDelegate.didStopWithError` 感知后自行退出，菜单显示「已停止」，同时停掉 AOA 桥（避免桥对着已死 helper 无限重连）。
- 安全边界：控制端口只绑定回环；Wi-Fi 仍强制 TLS + 指纹固定，明文端口只绑定回环。

## 8. 解码与渲染

- `XComponent({ type: 'surface' })` + `XComponentController.getXComponentSurfaceId()`；surface 变化（旋转、后台恢复）时 `setSurface` 触发解码器重建。
- 解码器建议默认 surface 模式；若 `SetSurface` 或首帧超时，回退 buffer 模式（NV12）并用 `OH_NativeWindow` 手动送帧或走 ArkTS 渲染（回退路径只求可用，不追延迟）。
- 渲染比例：等比适配、居中、黑边；`AspectRatio` 按 SESSION_CONFIG 宽高，`StreamPage` 在收到 config 后更新。
- 常亮：窗口 `keepScreenOn`；全屏与隐藏系统栏由 EntryAbility 设置。
- 统计：`StatsOverlay`（默认关闭，位于左上角）显示 `fps · Mbps · drop · p95` 与 `decode · e2e · RTT · 编码`，500ms 刷新；每次刷新都读取 `Runtime.stats` 当前实例，切通道后不会冻结。p95 是 e2e 的 300 样本滚动窗口（约 5s）。

## 9. 输入

- 采集：XComponent `onTouch`（含 `touches` 多点、`toolType`、压力、倾斜），归一化到画面内容区（去黑边）；工具条只由按钮自身拦截触摸，其余区域照常转发给 Mac。
- 播放页工具条：右下角常驻**半透明灰色齿轮（20vp）**，点击后从齿轮位置向上展开 调试 / 输入 / 键盘 / 断开 四枚 40vp 按钮，底部 X 收回齿轮；纯透明无底色。早期「右缘 15% 起滑」与右侧 14vp 把手方案已弃用。
- 状态语义：白 = 已开启，灰 = 未开启/不可用，断开为 灰 → 红（danger）两击确认；点击后均有 Toast 文案（触控已开启/关闭、键盘已打开/关闭、再点一次断开连接）。
- 图标资源：`assets/icon/{input,keyboard,disconnect,debug,gear,close}/`，前三个由 `tools/extract_icons.py` 从 `preview_contact_sheet.png` 第三排切出（按 alpha 连通域、核心 52/96 居中，四态同比例），其余由 `tools/gen_extra_icons.py` 自绘；同步到 `resources/base/media/ic_<action>_<state>.png`。
- 手势语义在客户端：与 `GestureMapper` 直译（长按 500ms→右键、双指滚动、捏合→⌘ 滚动、笔/橡皮擦、悬停）。
- 键盘：硬件 `onKeyEvent` → KeyMapping → KEY；软键盘用隐藏 `TextInput`，`onChange` 差量 → TEXT，退格 → KEY，回车 → TEXT "\n"。
- 服务端门控：`CTRL INPUT_ENABLED(3)` / `INPUT_DISABLED(4, reason)` 决定是否允许发送；面板上有输入开关；关闭或页面切走时 `releaseAll`（CTRL 2）。
- 手写笔：`SourceTool`→STYLUS/ERASER，压力与倾斜直传；悬停事件转 HOVER。

## 10. UI 与持久化

- **连接页**：状态文案、连接/断开、AUTO/Wi-Fi/TCP/USB 模式切换、发现 Mac、扫码配对、手动地址、配对链接粘贴；连接中禁用按钮、显示进度。
- **配对入口**：粘贴配对链接与扫码都可用。扫码用 `@kit.ScanKit` 的 `scanBarcode.startScanForResult`，系统扫码 UI 自带相机权限，App 不声明 CAMERA（已在本机验证，§16 #5）。
- **播放页**：全屏视频 + 右下角齿轮吸附的工具条（调试/输入/键盘/断开 + X 收回）；无返回按钮，退出走工具条「断开」。调试浮层默认关闭，打开后显示在**左上角**（不再放左下角）。
- **持久化**（preferences，键名沿用 Android 并新增 UI 项）：`host`、`port`、`fingerprint`、`device_id`、`transportMode`、`debugOn`、`inputOn`。传输模式与手填地址在下次启动恢复；调试信息与输入开关作为用户选择持久化（不再每次配置强制打开），键盘开关刻意不持久化。配对地址只在 **Wi-Fi 连接成功时**回写，USB/TCP 连接不会冲掉已配对地址。
- **HELLO 设备信息**：屏幕像素宽高、DPI、刷新率、旋转、`deviceInfo.productModel`；每次连接与每次旋转后重建（重连流程）。

## 11. 开源工程事项

- **许可证**：MIT（记录为本文档的决定，可改）。
- **仓库卫生**：不提交签名材料（`build-profile.json5` 中的 `signingConfigs` 由 DevEco 自动签名生成、每台机器不同——入库前清空并写入 `.gitignore` 策略）；不提交 `.hvigor/`、`oh_modules/`、`.idea/`、构建产物；探针资源（`probe720.h264`、探针页）删除。
- **README**：项目简介、功能与通道分级（Wi-Fi 一等、USB 实验）、构建步骤（DevEco Studio、SDK 版本、自动签名）、Mac 端依赖（Helper + AOA 桥）、已知限制（未实测机型、USB 厂商差异、AOA 模式隐藏 hdc）、隐私说明（无遥测、设备 ID 本地随机）。
- **文档**：协议文档指向上位设计；本设计随仓库发布。
- **版本号**：`clientVersion=1`（HELLO 字段），与 APK 一致。
- **兼容性声明**：`compatibleSdkVersion = 26`、`targetSdkVersion = 26`（下探到 12 留到 H5 评估）；USB 相关 API 自 14 起可用，低版本自动降级到 Wi-Fi 并提示。README 的设备矩阵只列已实测的 WEB-W00。

## 12. 方案取舍（已选）

| 方案 | 内容 | 放弃原因 |
|---|---|---|
| 纯 1:1 移植 | Kotlin 文件逐个翻译，Activity 全局变量照搬 | USB 授权（广播→await）、解码渲染、线程模型无法直译，最终仍要改；会把 1349 行 god-object 搬进 ArkTS |
| 完全重新设计 | 协议侧也重写，按理想模型重新组织 | 丢失 APK 已调稳的行为（BYE 重同步、关键帧门控、UDP 接管、退避参数），风险高 |
| **语义 1:1 + 结构重写（已选）** | 协议/输入/统计直译；传输抽接口；状态机显式化；解码渲染重写 | 保留行为确定性，丢掉 Android 管道债；唯一新设计量在状态机与 native 桥 |

## 13. 里程碑

| 阶段 | 内容 | 退出标准 | 状态（2026-11-17） |
|---|---|---|---|
| H1 | 工程骨架、Protocol/Stats、TCP + TLS（含指纹校验）、mDNS、粘贴配对、AVCodec surface 解码上屏、断线重连、设置持久化 | Wi-Fi 连上 Mac 出画面，60fps，统计可见 | 完成（模拟器 + 真实 Helper 验收） |
| H2 | UDP（native 收包 + NDK AES-GCM + 重组/NACK）+ FEEDBACK | 弱网下自动回退、断电重连、连续 30min 不断流 | FEEDBACK 完成；UDP 未实现 |
| H3 | 输入：触控/手势/键盘/笔 + 服务端门控 + 控制抽屉 | 与 Android 端行为逐项对照通过 | 完成 |
| H4 | USB AOA 传输接入（native fd + ArkTS 拆帧）+ AUTO 降级 + 热插拔恢复 | 本机 USB 路径 ≤50ms p95，拔插可恢复 | 完成：USB 授权/拒绝/拔插恢复/AUTO 优先/断开停轮询均真机通过；USB p95 20–30ms 常态（偶发关键帧尖峰）。AUTO 支持插线自动回切 USB |
| H5 | 旋转重配置、开源发布：README、LICENSE、仓库清理、Release 构建说明 | 全新机器按 README 能构建并连上 | 未开始 |

每个阶段结束在 WEB-W00 上真机验收，指标记入 `docs/`。Wi-Fi 实测：修复 TLS 1.3 收包停顿后，静止画面 P 帧 e2e 6–42ms；持续画面变化时由 FEEDBACK 驱动 Mac 降码率。

## 14. 风险

1. **只在一台设备验收**：其他鸿蒙机型（尤其手机、不同芯片）的 AVCodec surface、USB accessory、mDNS 行为未验证。README 必须写明，并对回退路径做保护。
2. **USB 厂商差异**：`/dev/usb_accessory` 读写语义、16KB 上限可能是本机驱动特性；其他设备可能不同，需要运行时容错（读失败 → 明确报错并回退）。
3. **TLS 自签证书与指纹校验**：依赖 `getRemoteCertificate()` 行为在不同 API 版本一致；若某版本拿不到证书，必须拒绝连接而不是降级为不校验。
4. **解码 surface 兼容**：部分设备可能不支持 surface 模式或首帧超时；必须实现 buffer 回退。
5. **系统杀后台/息屏**：v1 只承诺前台亮屏 + 常亮，不做后台保活；README 写明，避免用户预期落空。
6. **mDNS 权限与组播**：鸿蒙可能限制组播；手动地址与二维码是主路径。
7. **入口 UI 差异**：扫码依赖系统扫码 UI（`@kit.ScanKit`），不需要 App 声明相机权限；无法调起时保留粘贴配对链接。

## 15. 留给实现者的决定

- 状态机内部实现（类还是闭包）与事件命名细节。
- 控制工具条的布局与图标（已定：右下角齿轮吸附、向上展开四键 + X 收回；图标由 `assets/icon` 的切图/自绘脚本生成，右缘手势与竖条把手方案已弃用）。
- `StatsOverlay` 的排版与刷新频率。
- native 桥中 threadsafe function 的具体回调粒度（逐帧 vs 批事件）。
- 解码器低延迟参数的具体探测方式。
- 回退渲染（buffer 模式）的实现取舍。
- 单元测试组织（协议编解码优先用测试向量对照）。

## 16. 待验证项（实现期）

| # | 项 | 验证方式 | 状态 |
|---|---|---|---|
| 1 | `OH_VideoDecoder_SetSurface` 在本机实际渲染成功 | H1 首帧上屏 | 已验证（H1 验收） |
| 2 | `getRemoteCertificate()` 返回 DER 且指纹与 Mac 端一致 | H1 打印 SHA-256 与 QR 指纹对照 | 已验证（H1 验收） |
| 3 | native UDP 收包 + NDK AES-GCM 能否跟上 25Mbps（≈2600 包/秒） | H2 满速实测丢包率与 CPU 占用 | 未开始（H2） |
| 4 | 隐藏 TextInput 的软键盘文本差量行为 | H3 中文输入、退格、回车 | 已实现（H3） |
| 5 | 扫码能否在 WEB-W00 + 自动签名下直接调起（是否依赖 AGC 配置） | 真机点击扫码 | 已验证：`@kit.ScanKit` 系统扫码 UI 可直接调起，不依赖 AGC，App 无需 CAMERA |
| 6 | 旋转时画面恢复的交互 | 前后旋转各 3 次 | 已验证：旋转触发页面重建 → 新 surface + 解码器重开；未实现同连接重发 HELLO |
| 7 | 其他机型（手机/不同芯片）兼容性 | 社区反馈或自备设备 | 待社区 |
| 8 | HarmonyOS TLS 1.3 大帧收包停顿 | TLS 1.2 / 1.3 对比实测 | 已验证：1.3 在一个 16KB 记录后停顿数秒；固定 1.2 后 16KB 记录 33ms 内到齐 |