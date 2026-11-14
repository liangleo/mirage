# Mirage 设计文档

版本：v1.0（定稿，2026-11-13；2026-11-14 完成 M0–M2 真机验收，实现现状见 §16）
日期：2026-11-13
定位：把 Android 平板/手机变成 Mac 的扩展屏或镜像屏。

---

## 1. 意图与阶段划分

Mirage 由两个程序组成：Mac 端 Helper（菜单栏 App + 后台进程）和 Android 端 App。插线或同网后，Android 设备成为 Mac 的一块真实显示器。

**分阶段交付：**

- **v1.0（本文档主体）：只做扩展屏显示。** Mac 画面出现在 Android 设备上，设备列入 macOS 显示器列表，窗口可拖入。用 Mac 自己的鼠标键盘操作，设备本身不接收任何输入。
- **v1.1（另排期）：输入回传。** 触控、手势、键盘、手写笔。
- **v1.2（另排期）：手写笔增强。** CGEvent 不满足时再评估虚拟 HID。

**v1.0 成功标准（验收以此为准）：**

1. 扩展屏模式下列入 macOS 显示器列表，窗口可拖入，Mac 鼠标可跨屏移动。
2. USB 有线端到端延迟 p95 ≤ 50ms（设计预算 ~35ms），Wi-Fi 5GHz p95 ≤ 100ms。
3. 60fps 稳定；设备与链路允许时支持 90/120Hz。
4. 画面按设备原生宽高比显示，无拉伸、无黑边错位。
5. 配对后插入 USB，在「设备已解锁、Mirage 不在前台、Mac Helper 运行中」的条件下，从插入到出画面 ≤ 3 秒，无需手动操作；息屏/锁屏需用户唤醒，不计入。
6. 连续使用 2 小时不断连、无内存增长。

**v1.0 非目标：**

- 一切输入：触控、手势、键盘、手写笔（v1.1）。
- 音频转发、剪贴板同步、文件传输、公网穿透（远程桌面）。
- Windows / Linux 作为主机；原生 HarmonyOS NEXT 版（鸿蒙先用卓易通跑 APK）。
- Mac App Store 上架；HDR / 10bit；多客户端同时连接。
- Intel Mac（见 §2）。
- DRM 保护内容（Netflix 等）在被捕获屏上会黑屏，属预期行为。

**反目标（做到了也算失败）：**

- 显示延迟不达标，靠加功能弥补。
- 演变成账号体系 + 云中转的远程桌面产品。

---

## 2. 约束与前提

| 项目 | 约束 |
|---|---|
| Mac 端系统与硬件 | macOS 14+（Sonoma 及以后），**仅 Apple Silicon**。`CGVirtualDisplay` 为私有 API，需运行时探测并准备降级 |
| Android 端 | Android 8.0+（API 26），目标 SDK 跟随当年最新 |
| 鸿蒙 | HarmonyOS 4.x 及更早直接装 APK；NEXT/5.x 通过卓易通运行，作为兼容性测试项，不承诺 AOA/adb |
| 分发 | Mac 用 Developer ID 签名 + 公证，官网 dmg + Homebrew Cask；Android 用 Google Play / AppGallery / 官网 APK |
| 权限 | Mac 上 v1.0 需要「屏幕录制」；Wi-Fi 里程碑另需「本地网络」；「辅助功能」在 v1.1 输入阶段才需要 |
| 网络 | 有线优先；Wi-Fi 要求 5GHz，2.4GHz 仅作能用 |
| 真机 | 已有 Android 平板与手机各一台，平板作为性能验收基准，手机作兼容性验证 |

**已定技术决策（设计者决定，非用户逐条确认）：**

1. **v1.0 只做显示，不做输入**（用户决定，2026-11-13）。协议中预留 INPUT 消息，但 v1.0 不实现发送与注入。
2. **仅 Apple Silicon**（用户决定）。构建与验收不做 Intel 矩阵。
3. **手写笔走 CGEvent 尽力而为**（用户决定），虚拟 HID / DriverKit 不在当前范围；v1.2 再评估。
4. **不做共享 C++ 核心。** 只有 Swift 与 Kotlin 两个实现，协议靠本文档 + 测试向量对齐。等出现第三个平台（原生鸿蒙）再抽核心库。
5. **默认 H.264 High profile**，HEVC 作为双方能力都满足时可选开关。
6. **加密用 TLS 1.2+（两端默认协商到 1.3）+ 证书固定**，用于 TCP（adb reverse / Wi-Fi）路径；不强制 1.3，因为 Android 8/9 平台最高只到 1.2。AOA USB 在 v1.0 为明文，理由见 §11。
7. **有线路径为单条 TCP 字节流**，承载视频、控制、心跳；Wi-Fi 里程碑再引入 UDP 视频通道。
8. **有线优先**：目标形态是 AOA 免调试 USB；`adb reverse` 作为开发期与兜底。
9. **此前的网页版原型代码不作为起点**（从未编译、协议不同），仅作参考。

---

## 3. 架构总览

```
┌──────────────── Mac Helper ────────────────┐        ┌──────── Android App ────────┐
│ CGVirtualDisplay（虚拟屏，可选）            │        │ Compose UI（连接页/工具条） │
│      ↓                                     │        │                             │
│ ScreenCaptureKit 捕获（NV12）              │  视频  │ MediaCodec 硬解             │
│      ↓                                     │ ─────→ │      ↓                      │
│ VideoToolbox 硬编 H.264（低延迟）          │        │ SurfaceView 直出            │
│      ↓                                     │        │                             │
│ 协议层（分帧/背压/统计）                    │  控制  │                             │
│ 传输：AOA | adb reverse | Wi-Fi            │ ←────→ │                             │
│                                             │  v1.1  │ 触控/笔/键盘采集（预留）    │
│ CGEvent 注入（v1.1）←───────────────────────│ ←───── │                             │
└────────────────────────────────────────────┘        └─────────────────────────────┘
```

**分层原则：**

- v1.0 只有视频下行 + 控制/心跳通道；输入通道在协议中预留、不实现。
- 客户端只上报能力与状态；未来手势语义（长按右键、双指滚动等）全部在 Mac 端解释，保证不同客户端行为一致。
- UI 各端原生实现，不引入 Flutter/RN。

---

## 4. 仓库结构

```
mirage/
├── docs/                      # 本文档、协议规范、测试记录
├── protocol/                  # 协议测试向量（十六进制样例 + 期望解析结果）
├── mac/                       # Swift Package
│   ├── Package.swift
│   ├── Sources/MirageCore/    # 协议编解码、会话状态机、传输抽象
│   ├── Sources/MirageHelper/  # 捕获、编码、USB 监听（后台进程）
│   └── App/                   # SwiftUI 菜单栏 App（薄壳，调用 Helper）
├── android/                   # Gradle 工程（app/mirage/{net,video,ui}）
└── tools/                     # mock_mac.py、mock_android.py、延迟测量、收包解析
```

---

## 5. 协议规范 v1

### 5.1 帧格式（流模式）

所有消息走同一条可靠字节流：

```
[u32 length][u8 type][payload]
```

- 大端；`length` = 1 + payload 长度，不含自身。
- 单帧上限 8 MiB，超限视为协议错误并断开。
- 版本协商失败时 Mac 返回 `BYE` 并附可读原因。

| type | 名称 | 方向 | v1.0 |
|---|---|---|---|
| 0x01 | HELLO（能力上报） | 客户端 → Mac | ✅ |
| 0x02 | SESSION_CONFIG | Mac → 客户端 | ✅ |
| 0x03 | VIDEO | Mac → 客户端 | ✅ |
| 0x04 | INPUT | 客户端 → Mac | 预留（v1.1） |
| 0x05 | FEEDBACK | 客户端 → Mac | ✅ |
| 0x06 | CTRL | 双向 | ✅ |
| 0x07 | PING / PONG | 双向 | ✅ |
| 0x08 | BYE | 双向 | ✅ |

未知 type 必须忽略而不是断开，保证向前兼容。

### 5.2 HELLO

```
u8  proto_ver = 1
u16 client_ver
u8  device_id[16]                    # 首次安装生成并持久化，用于 Mac 端设备识别
u16 screen_w_px, u16 screen_h_px     # 设备物理像素
u16 xdpi, u16 ydpi
u8  max_fps                          # 0 = 不限制
u8  codecs                           # bit0 H.264, bit1 HEVC
u8  features                         # bit0 笔, bit1 压感, bit2 倾斜, bit3 悬停（v1.1 使用）
u8  rotation                         # 0/1/2/3 对应 0/90/180/270
u8  name_len
... name（UTF-8，设备显示名）
```

### 5.3 SESSION_CONFIG

```
u16 width_px, u16 height_px          # 编码分辨率（= 虚拟屏物理像素）
u8  fps
u8  codec                            # 1 = H.264, 2 = HEVC
u32 bitrate_bps
u8  rotation
```

方向或分辨率变化时 Mac 重发该消息，重建虚拟屏与编码器，并强制下一帧为 IDR。

### 5.4 VIDEO

```
u8  codec
u8  flags                            # bit0 = 关键帧
u32 frame_id
u64 capture_ts_us                    # Mac 单调时钟，用于端到端测量
[u32 reserved]
... Annex-B 码流（关键帧前带 SPS/PPS）
```

### 5.5 INPUT（v1.1 实现，v1.0 仅定义）

```
u16 count
count × 32 字节：
  u8  kind        # 1 down, 2 move, 3 up, 4 cancel, 5 hover
  u8  pointer_id
  u16 buttons     # bit0 主键, bit1 次键, bit2 笔侧键, bit3 橡皮擦
  f32 x, f32 y    # 0..1，相对画面内容区（已去掉黑边）
  f32 pressure    # 0..1
  f32 tilt_x, f32 tilt_y   # 角度
  u64 ts_us
```

一个 `MotionEvent` 及其历史点（`getHistoricalX/Y`）合并为一个 INPUT。键盘事件在 v1.1 另行扩展（追加新 type，不改动本消息）。

### 5.6 FEEDBACK 与 PING

- FEEDBACK（10Hz）：渲染 fps、解码耗时、最近 1 秒丢帧数、估算排队帧数。
- PING/PONG：携带 `u64` 回显时间戳；每秒一次，用于 RTT 与时钟偏移估计，进而计算端到端延迟。
- 控制通道在断开前释放所有按下状态（v1.1 起适用），防止卡键。

### 5.7 握手、配对与加密

- TCP 路径（adb reverse / Wi-Fi）使用 **TLS 1.2+**，由系统协商（通常升到 1.3）；**不强制 1.3**，否则 Android 8/9 无法连接。
- Mac 自签身份：`SecKeyCreateRandomKey`（P-256）生成私钥，用 `apple/swift-certificates` 自签证书（Security.framework 没有公开的 X.509 创建 API）；用 `SecItemAdd` 把 key + cert 存入 login keychain，之后按 `kSecClassIdentity` 查询即可，避免每次启动授权弹窗。
- 服务端：`NWListener` + `NWProtocolTLS.Options()`，`sec_protocol_options_set_local_identity`；客户端在 verify block 里取叶证书（`SecTrustCopyCertificateChain`），比对 SHA-256 指纹。
- Android 端：`SSLContext("TLS")` + 自定义 `X509TrustManager`，对 `chain[0].encoded` 做 SHA-256，用 `MessageDigest.isEqual` 与固定指纹比较，不符抛 `CertificateException`；`startHandshake` 放后台线程。原生 `SSLSocket` 默认不做主机名校验，身份完全依赖指纹固定——二维码必须携带指纹。若改用 OkHttp，它 pin 的是 SPKI 哈希而非证书 DER 哈希，不要混用。
- **证书生命周期**：必须使用稳定签名，ad-hoc 签名每次构建都可能重新弹窗；证书丢失意味着所有已配对设备都要重新配对。
- 首次配对二维码：
  `mirage://pair?v=1&host=…&port=…&fp=<64 位 hex>&name=<urlencoded>&id=<uuid>`。
  客户端必须严格校验 scheme、版本与指纹长度（信任边界）。Mac 端用 CoreImage `CIQRCodeGenerator` 生成，无第三方依赖。
- AOA 路径：v1.0 为明文（见 §11）；首连采用 TOFU，Mac 菜单栏弹出设备名与确认按钮，确认后把 `device_id` 存入白名单，之后静默连接。非白名单设备每次连接都需确认。
- Wi-Fi UDP 阶段：在 TLS 通道内下发随机会话密钥，视频数据报用 ChaCha20-Poly1305 加密，包序号作 nonce 前缀。

### 5.8 兼容性

- `proto_ver` 不兼容时明确报错，不做静默降级。
- 新增字段一律追加在末尾，旧实现忽略未知尾部字段。
- 每个里程碑冻结一组测试向量到 `protocol/`，两端共享。

---

## 6. Mac Helper 设计

### 6.1 虚拟显示器

- 用 `CGVirtualDisplay`（私有 API）创建真实扩展显示器，可被 ScreenCaptureKit 枚举、可被系统设置识别。
- 尺寸策略：以设备物理像素为编码出口，以像素/2 作为逻辑点尺寸（HiDPI），保持设备原生宽高比，避免拉伸与错位。例如 2560×1600 设备 → 逻辑 1280×800 @2x。
- 提供三档逻辑尺寸预设（贴合设备 / 更大字体 / 更多空间），默认贴合设备。
- 旋转时重建虚拟屏并重新协商。
- 降级路径：私有 API 失效或创建失败时自动切「镜像主屏」模式，并在 UI 明示当前是镜像而非扩展。
- 代价：不能上 Mac App Store；公证不检查私有 API，Developer ID 分发可行。

**实现要点（来自社区逆向资料，未在线复核）：**

- 通过私有头文件映射（clang target / 桥接头）调用：`initWithDescriptor:`、`applySettings:`、`displayID`；descriptor 填 `name`、`maxPixelsWide/High`、`sizeInMillimeters`、vendor/product/serial。
- mode 用**点尺寸**描述（如 `CGVirtualDisplayMode(1280, 800, 60)`），`settings.hiDPI = 1`。
- `applySettings` 后约 0.25 秒进入 `CGGetActiveDisplayList` 与 `SCShareableContent.displays`；启动后必须自检「已 online 且可见」，失败即降级。
- **旋转不能原地切 mode**（会返回 `kCGErrorIllegalArgument`），必须换方向 + 新 serial 重建，否则可能恢复旧镜像。
- 较新系统收紧了尺寸约束：macOS 26.1 起预留大尺寸需要足够的物理面积，27.2 起对短边与 HiDPI 高度有下限；尺寸比例像电视会被强制镜像。启动自检要覆盖这些失败态。
- 睡眠/锁屏期间释放虚拟屏可能留下 ghost 显示器；释放流程需在唤醒后清理。
- 参考实现：BetterDisplay、DeskPad、vdisplay、superconnect（均使用同一私有 API）。
- **本机实测（2026-11-13，macOS 27.2.1，Apple Silicon）**：私有类均可加载，2560×1600（逻辑 1280×800 @2x、60Hz）创建成功，`displayID=7`，1 秒内 online 且出现在 `CGGetActiveDisplayList`，未镜像。探针见 `tools/verify/cgvd_probe.m`。

### 6.2 捕获

- `SCContentFilter(display:excludingWindows:)` 按 displayID 捕获虚拟屏；虚拟屏创建后需重试枚举再建立 stream。
- **捕获尺寸必须用显示器像素尺寸**：`CGDisplayCopyDisplayMode(id).pixelWidth/Height`。本机实测：1280×800 @2x 的虚拟屏，`SCDisplay.width/height` 报 1280×800（点），按它配置只会得到 1280×800 帧；按像素配置得到 2560×1600 帧。
- 像素格式 `420v`（NV12 VideoRange）或 `420f`（FullRange），零拷贝交给编码器。
- `queueDepth = 3`（实测可到 8），`minimumFrameInterval` 对齐目标帧率，`showsCursor = true`（光标移动会产生脏矩形，属于期望行为）。
- **静止画面行为（本机实测，macOS 27.2.1）**：SCK 会持续回调，不会停发。虚拟屏静置 8.5 秒内有 264 帧 `status = .idle`、65 帧 `.complete`，其中只有 64 帧带非空脏矩形；帧间隔最大约 38ms，不能靠「多久没回调」判断静止。
- 帧信息从 **sample buffer 的 sample attachments** 读取（`CMSampleBufferGetSampleAttachmentsArray`），不是 `CMCopyDictionaryOfAttachments`。键为 `SCStreamFrameInfo.status`、`.dirtyRects`（矩形桥接为字典，需按 `Width/Height` 解析）。
- 编码策略：仅当 `status == .complete` 且存在非零脏矩形时编码；`.idle` 与空脏矩形帧直接丢弃；每秒发一个保活包。若后续需要按脏区部分更新，再引入区域编码。
- 不可用 `AVCaptureScreenInput` 捕获虚拟屏，必须用 SCK。
- 已知黑屏条件：虚拟屏未 online、被系统强制镜像、睡眠/锁屏。捕获层需在无有效帧超时后检查显示器状态并重连。
- 权限：只需「屏幕录制」。最新系统会定期复核授权，运行时必须处理授权被关闭的情况（提示并停止推流）。

### 6.3 编码

- VideoToolbox 硬编，关键参数：
  - `kVTVideoEncoderSpecification_EnableLowLatencyRateControl = true`，**在创建会话时通过 encoder specification 传入**，不是运行时 SetProperty；可用版本为 macOS 11.3+（非 13+）。启用后为无限 GOP、无 B 帧/前瞻、仅 High profile。
  - `kVTCompressionPropertyKey_RealTime = true`
  - `AllowFrameReordering = false`（无 B 帧）
  - `MaxFrameDelayCount = 0` **在低延迟码控下不被支持**：本机实测返回 `-12900`（kVTPropertyNotSupportedErr），不要依赖该属性；延迟由低延迟码控内部管理。
  - 码率：`AverageBitRate` 为软上限，`DataRateLimits = [bytes, 秒]` 为硬上限；USB 20–40 Mbps，Wi-Fi 8–25 Mbps，运行时可调。
  - 因低延迟码控是无限 GOP，必须自行用 `kVTEncodeFrameOptionKey_ForceKeyFrame` 触发 IDR：首帧、丢帧恢复、码率/分辨率变化、5 秒兜底。
- 零拷贝：SCK 输出的 `420v/420f` `CVPixelBuffer` 是 IOSurface-backed，直接 `EncodeFrame`；不要转 BGRA（约 14ms/帧，直通约 3ms）。
- VideoToolbox 输出 AVCC 格式，需转 Annex-B：用 `CMVideoFormatDescriptionGetH264/HEVCParameterSetAtIndex` 取参数集，把每个长度前缀换成 `00 00 00 01`；IDR 前重发 SPS/PPS（HEVC 还需重发 VPS）。
- HEVC 仅在客户端 HELLO 声明支持且实测解码延迟达标时启用，默认关。

### 6.4 背压

- 非阻塞写。若内核发送缓冲满（或应用层积压超过 3 帧），丢弃当前帧，等待下一个关键帧再恢复发送——延迟优先于画质。
- 不使用无界发送队列；任何排队都是延迟。

### 6.5 输入注入（v1.1，v1.0 不实现）

设计先记于此，v1.1 排期时细化：

- `CGEvent` 注入鼠标移动、按键、滚轮；需要「辅助功能」权限。
- 手势解释统一放在 Mac 端：

| 客户端事件 | Mac 行为 |
|---|---|
| 单指点按 | 左键单击 |
| 双击（300ms、10px 内） | 双击 |
| 单指拖动 | 左键拖拽 |
| 长按 500ms | 右键 |
| 双指滑动 | 滚动 |
| 双指捏合 | ⌘+滚轮（缩放），可配置关闭 |
| 笔 | 绝对定位指针，设置 tablet 压力/倾斜字段；侧键→右键，橡皮擦→按键位 |

- 坐标：客户端发送相对画面内容区的归一化值，Mac 映射到虚拟屏全局坐标矩形；注入前做范围校验与限速。
- 会话断开或客户端发 `cancel` 时立即释放所有按下的按键与鼠标。
- 已知限制：CGEvent 合成的 tablet 事件可能被 Photoshop 等依赖 HID 驱动的 App 忽略；v1.2 再评估虚拟 HID。

### 6.6 菜单栏 App 与权限引导

实现现状（M2）：SwiftUI 菜单栏 App 默认只在状态栏运行，主界面为单实例窗口；菜单栏保留启动/停止服务、模式、分辨率、帧率、打开主界面等快捷项。主窗口提供启动/停止服务、启动 App 后自动启动服务、模式/分辨率/帧率切换，以及带时间戳和自动滚动的内嵌日志。App 会识别并接管已在运行的 helper，停止时结束 helper 进程。日志默认写入 `~/Library/Logs/Mirage/helper.log`。

目标形态（后续里程碑）：设备列表、码率预设、开机自启（`SMAppService`）、Helper 常驻（LaunchAgent）与 USB 热插拔自动拉起尚未实现。

### 6.7 打包

- Swift Package 构建 Helper + .app 外壳；Developer ID 签名、公证、dmg 分发，Homebrew Cask。仅 arm64。
- 随包携带 `adb`（仅在用户选择 adb 模式时调用，Apache 2.0）与 `libusb`（LGPL，动态链接）。

---

## 7. Android App 设计

### 7.1 连接与发现

- 有线：优先 AOA（见 8.1）；开发期用 `adb reverse`。
- Wi-Fi：`NsdManager` 发现 `_mirage._tcp`（API 34+ 用 `registerServiceInfoCallback`，旧版本用 `resolveService`），或扫二维码直连；mDNS 失败时回退手动地址。
- 扫码库用 ZXing（`com.journeyapps:zxing-android-embedded`，仅需 CAMERA 权限）；不用 ML Kit——它依赖 GMS，鸿蒙或无 GMS 设备不可用。
- 首页：最近设备、手动地址输入、二维码扫描、连接状态；记住上次成功地址。

### 7.2 解码与渲染

- `MediaCodec` 在 M1/M2 实现中采用同步模式 + 专用 HandlerThread；异步回调模式保留为后续降低输入阻塞的优化项。输出直接绑定 `SurfaceView` 的 Surface（不用 TextureView，少约一帧合成延迟，并避免与 Compose 图层串层）。
- 关键键：`KEY_LOW_LATENCY=1`（API 30+，且仅当解码器声明支持时设置）、`KEY_PRIORITY=0`（API 28+）、`KEY_OPERATING_RATE`=目标刷新率；低版本逐项降级。
- 厂商私有低延迟键（高通 `vendor.qti-ext-dec-low-latency.enable`、海思 `vendor.hisi-ext-low-latency-video-dec.callback-method` 等）按解码器名 / `Build.HARDWARE` 白名单启用，逐键 try/catch——个别 ROM 会抛 `IllegalArgumentException`；留总开关。MTK/三星无稳定公开键，不猜。
- 参数集：优先把带起始码的 SPS/PPS 填入 `csd-0/csd-1`，或先送 `BUFFER_FLAG_CODEC_CONFIG`；IDR 前必须就绪，参数集变化时重建解码器。
- 收到完整帧立刻送解；不设抖动缓冲。`releaseOutputBuffer(index, true)` 即刻入队渲染，时间戳只用于统计，不用于排程（定时渲染仅适用于 SurfaceTexture 路径）。
- 输出积压时只渲染最新帧并请求 IDR。
- `Surface.setFrameRate()`（API 30+）对齐刷新率；API 23–29 回退 `preferredRefreshRate`/`preferredDisplayModeId`，均需 try/catch。注意硬解内部通常有 1–3 帧缓冲，低延迟键约能压到 1 帧，剩余延迟在 SurfaceFlinger 合成。
- Surface 重建（旋转、后台切换）会导致解码器失效，需完整重建解码器。
- 画面等比适配，默认居中；黑边区域 v1.0 仅影响观感，v1.1 起不接收输入。

### 7.3 输入采集（v1.1）

- 关闭系统边缘手势干扰：`systemGestureExclusionRects` + 沉浸式全屏。
- 原始 `MotionEvent` 全量采样：历史点、`AXIS_PRESSURE`、`AXIS_TILT`、`TOOL_TYPE_STYLUS/ERASER`、`BUTTON_STYLUS_PRIMARY`、悬停。
- 客户端只做坐标归一化（含按当前画面内容区去黑边），不做手势语义。

### 7.4 运行与适配

- 前台服务保活、屏幕常亮、断线指数退避重连。
- Wi-Fi 下申请低延迟 Wi-Fi 锁（`WifiManager.WifiLock` + `WIFI_MODE_FULL_LOW_LATENCY`）。
- 横竖屏切换时重发 HELLO 并等待新的 SESSION_CONFIG。
- 显示调试浮层：fps、码率、解码耗时、丢帧数、端到端延迟、RTT（decode/e2e/rtt，单位 ms，可关闭）。
- 卓易通（鸿蒙 NEXT）：不承诺可用。已知风险——USB accessory 大概率不通、ADB 不可用（鸿蒙用 hdc）、NSD 组播可能被容器网络阻断、Wi-Fi 低延迟锁可能无效、解码可能退回软解。连接页必须保留手动输入 IP 与二维码兜底，并允许关闭低延迟键。

### 7.5 UI

- Compose：连接页 + 全屏显示页。
- 全屏时边缘滑出工具条（v1.0 仅触屏操作）：画质预设、显示统计、断开。
- v1.0 设备本身不接收输入，工具条是为了连接期间可退出/调参；后续输入功能上线后需重新设计工具条触发方式，避免与触控冲突。

---

## 8. 传输层

### 8.1 USB / AOA（有线首选）

- Mac 用 libusb 走 Android Open Accessory 协议：控制请求 `GET_PROTOCOL=51`（返回 u16 版本）→ `SEND_STRING=52`（字符串 ID 0 厂商 / 1 型号 / 2 描述 / 3 版本 / 4 URI / 5 序列号）→ `START=53`。AOA2 另有 HID/音频请求，音频自 Android 8 废弃，本方案不用。
- 设备重新枚举为 `0x18d1:0x2d00`（纯 accessory）或 `0x18d1:0x2d01`（accessory + adb，仅当已开调试）。App 通过 `USB_ACCESSORY_ATTACHED` intent 自动拉起，**用户无需开启 USB 调试**。
- Android manifest：`uses-feature android.hardware.usb.accessory`；activity 加 `USB_ACCESSORY_ATTACHED` intent-filter 与指向 `res/xml` 的 meta-data（`<usb-accessory manufacturer=… model=…>`，**不要过滤 version**）。带 filter 即自动授权，无需额外权限；Android 12+ 需 `android:exported`。
- 数据走一对 bulk 端点（端点号从描述符读取），逻辑包上限 16 KiB。**两端读写块大小必须一致**：设备一次 read 的缓冲决定 host 可写入的长度，不匹配会静默截断甚至死锁。
- 时序坑：设备侧可能先发数据，host 必须先读再写；`START` 后原 libusb handle 失效，需关闭并在重枚举后重新打开。
- v1.0 明文传输（见 §11）；TLS 若将来叠加，需要 Security.framework/SSLEngine 套在 bulk 管道的自定义 TLS 层，属于额外工作量。
- macOS 侧：libusb 打开设备为独占（`USBDeviceOpenSeize`），Android File Transfer / OpenMTP / adb 占用时会返回 `kIOReturnExclusiveAccess`，UI 需提示关闭这些工具；不要用 `auto_detach_kernel_driver`（需要额外权限且会触发重枚举）。非沙盒 Developer ID 无需 USB entitlement；沙盒才需 `com.apple.security.device.usb`。
- 打包：libusb dylib 的 install_name 指向 Homebrew 绝对路径，需改 `@rpath` 并重新签名（公证要求所有 Mach-O 已签）；或静态链接并履行 LGPL 可重链接义务。
- 已知失败模式：个别 ROM 的 `GET_PROTOCOL` 失败；USB 3 口重枚举异常而 USB 2 正常；App 未安装/被强停时设备卡在 accessory 模式需拔插。
- 复杂度估计 8–15 人天（host + Android + 打包 + 机型矩阵）。参考实现：9elements/aoakvm、rustscreen。

### 8.2 adb reverse（开发期与兜底）

- Mac 监听 `127.0.0.1:7777`，用户执行 `adb reverse tcp:7777 tcp:7777`，手机连 `127.0.0.1:7777`。
- 实现成本最低，作为 M1 的联调通道与 AOA 失败时的兜底；需用户开启 USB 调试。

### 8.3 Wi-Fi（M4）

- 载荷 1200 字节（加 IP/UDP 后不触发分片），视频头 16 字节：全局 seq、frame_id、frag_idx、flags（SOF/EOF/关键帧）；FEC 块信息可选。
- 丢包按 seq 空洞检测，等待约 1 RTT 发 NACK bitmap；每包最多重传一次，超过帧 deadline 即丢帧、不阻塞后续帧。
- 关键帧缺任一分片整帧不可用，优先补齐；**不要轻易请求 IDR**——25 Mbps 下 IDR 可能数百 KB，占空口 100ms 以上。
- v1 只做 NACK：XOR FEC 默认关闭（可留开关），RS FEC、完整 GCC/SCReAM、多 FEC block 均不做。码控用简化延迟梯度：客户端每 100ms 上报到达时延梯度与解码队列深度，超阈值降 20–30%，平稳后慢升。
- 码率预设：2560×1600@60 建议 15 / 25 Mbps 两档（约 0.03–0.1 bpp，文字与渐变容易糊，需实测定档）。
- 控制与握手走 TLS/TCP；UDP 会话密钥经 TLS 通道下发。
- 发现用 mDNS（`_mirage._tcp`，TXT 记录放 v/fp/id/name）。mDNS 是 link-local：跨 VLAN、访客网络、AP isolation 必失败；macOS 15+ 本地网络权限被拒时静默失败。因此二维码 + 手动 IP 是主路径，mDNS 仅 best-effort；非 5GHz 场景在 UI 提示。AP 排队、省电模式与多设备竞争是主要瓶颈，带宽本身不是（5GHz Wi-Fi 5/6 足够 25 Mbps）。
- 估算 6–9 人天；若设备只用于有线场景，本里程碑可整体后置。

### 8.4 传输矩阵

| 通道 | Android | 鸿蒙 NEXT（卓易通） | Mac 实现 | 用途 |
|---|---|---|---|---|
| AOA USB | ✅ 免调试 | ⚠ 大概率不可用，需实测 | libusb | 有线首选 |
| adb reverse | ✅ 需调试 | ⚠ 待测 | 内置 adb | 开发/兜底 |
| Wi-Fi TCP/UDP | ✅ | ✅ | Network.framework | 无线 |
| hdc fport | ❌ | ✅ 需调试 | 内置 hdc | 鸿蒙有线备选（后续） |

---

## 9. 延迟预算与测量

**USB 有线目标预算：**

```
捕获 8ms → 编码 6ms → 传输 3ms → 解码 8ms → 渲染 8ms ≈ 33ms
```

达成手段：NV12 零拷贝、无 B 帧、实时码控、无抖动缓冲、发送积压即丢帧、SurfaceView 直出、TCP_NODELAY。

**测量方法：**

1. 软件打点：`capture_ts_us` + 客户端解码/渲染时间戳 + PING 估时钟偏移。偏移用滑动窗口内的最小 RTT 估计（假设路径对称），局域网误差约 0.5–2ms；调试浮层实时显示分阶段耗时。SCK 的 sample attachments 还提供 `SCStreamMetricCaptureLatencyTime`，可直接作为捕获段耗时。
2. 光子到光子：Mac 显示高速计时器，相机同拍两块屏。240fps 的量化误差约 4.2ms，建议 480/960fps 或光敏传感器 + 示波器（可到 1ms 内）；主要误差来自曝光时间与两屏刷新相位。
3. 弱网：Network Link Conditioner / `pfctl` 模拟丢包 1–5%、抖动 20ms，验证码控与恢复。
4. 机型矩阵：现有平板（性能验收基准）与手机（兼容性）；后续补高通/联发科/麒麟各一款及一台卓易通环境设备。

---

## 10. 分辨率、坐标与方向

- 虚拟屏逻辑尺寸 = 设备物理像素 / 2，HiDPI 2x，宽高比与设备一致。
- 客户端按「内容区等比适配」渲染；v1.0 无输入，归一化坐标映射在 v1.1 启用。
- 方向变化：客户端重发 HELLO；Mac 重建虚拟屏与编码器，发新 SESSION_CONFIG，强制 IDR。
- DPI 差异导致的 UI 过小/过大，由逻辑尺寸预设调整，不改变编码分辨率。

---

## 11. 安全与隐私

- 屏幕内容只在两台本机设备间传输，不上云、不落盘。
- TCP 路径使用 TLS 1.2+（默认升到 1.3）+ 证书固定；首次配对经二维码或 TOFU 确认。
- **AOA v1.0 明文**：USB 是点对点物理连接，威胁模型是网络窃听而非物理接触；在 libusb bulk 上自建 TLS 栈的工作量与收益不匹配，故 v1.0 接受明文并在产品说明写明。接入输入（v1.1）时重新评估。
- 设备识别：HELLO 携带持久化 `device_id`；Mac 端首次连接弹窗确认设备名，确认后入白名单。该 ID 可被本机其他 App 伪造，不构成对抗恶意本机软件的防护。
- 日志只记录性能指标，默认不记录屏幕内容。
- 输入注入限速并校验坐标范围（v1.1）；断开立即释放按键。

---

## 12. 里程碑

| 阶段 | 内容 | 估算（单人，AI 辅助） |
|---|---|---|
| M0 | 协议冻结（§5 + 测试向量）、Mac 捕获编码 CLI、`mock_mac.py` | 2–3 天 |
| M1 | Android 解码显示 + adb reverse 通链，镜像模式跑通 | 2–3 天 |
| M2 | CGVirtualDisplay 真扩展屏、分辨率/方向协商、画面适配 | 3–5 天 |
| M3 | AOA 免调试 USB、自动拉起、菜单栏 App、屏幕录制权限引导 | 8–15 天 |
| M4 | Wi-Fi：mDNS、UDP、NACK、码率自适应、二维码配对、TLS | 6–9 天 |
| M5 | 多机型矩阵、性能调优、打包公证、分发 | 3–5 天 |

v1.0 合计约 **24–40 人天（5–8 周）**。顺利情况下约 4 周可到「能日常用」；仅有两个可能超期项：`CGVirtualDisplay` 私有 API 的可用性（失效则镜像模式交付），以及 AOA 在现有设备上的兼容性（失败则回退 adb reverse）。

**最小验证优先：** M0 + M1 约 1 周内可跑通「Mac 画面出现在设备上」，先验证延迟预算是否成立，再投入扩展屏、AOA 与无线。

**输入阶段（v1.1，需另行排期确认）：** 触控与手势回传、CGEvent 注入、键盘；估算 3–4 周。手写笔增强（v1.2，含虚拟 HID 可行性评估）另计。

每个里程碑结束的标准：真机跑通、延迟/画质指标记录到 `docs/`，不达标不进入下一阶段。

---

## 13. 风险与待验证项

1. **CGVirtualDisplay 私有 API**：随系统升级可能失效；macOS 26.1 起对尺寸/物理面积有约束，27.2 起对短边与 HiDPI 高度有下限，尺寸像电视会被强制镜像。需运行时探测「已 online 且可捕获」，失败降级镜像；每个新系统版本先在开发机验证再排期。
2. **AOA 兼容性**：两端 16 KiB 读写块必须一致否则静默截断；device-speaks-first 竞态；USB 3 口重枚举异常；MTP 工具独占设备；个别 ROM 的 `GET_PROTOCOL` 失败。需真机矩阵，失败时回退 adb reverse。
3. **厂商解码器缓冲**：部分机型硬解内部缓冲大，延迟可达 60ms+；需白名单与「低延迟模式」开关，接受部分机型不达标。
4. **卓易通环境**：AOA/adb 大概率不可用，Wi-Fi 是鸿蒙用户主路径。
5. **macOS 屏幕录制授权**：新版系统会周期复核授权；SCK 应用通常不再月弹，但授权可能被用户关闭，运行时必须处理失效。
6. **DRM 内容黑屏**：产品说明中写明。
7. **HEVC 解码延迟**：低端机可能更高，默认关闭，实测后再决定是否开启。
8. **Wi-Fi 弱网体验**：2.4GHz 与拥塞环境下不可控，引导 5GHz；码率自适应需充分调参。
9. **输入阶段的兼容性风险**（后置）：CGEvent 手写笔压感可能不被 Photoshop 等 App 识别；v1.1 排期时先做最小验证再定验收。
10. **商标与命名**：上架前检索 Mirage 在应用商店与商标库的占用情况。
11. **TLS 证书生命周期**：ad-hoc 签名每次构建可能重新触发钥匙串弹窗；证书丢失需所有已配对设备重新配对。必须使用稳定签名，并把身份持久化在 login keychain。
12. **Android 8/9 仅支持 TLS 1.2**：不能强制 1.3，否则目标最低版本不可用。
13. **本地发现不可靠**：macOS 15+ 本地网络权限、VLAN、访客 Wi-Fi、AP isolation 都会让 mDNS 静默失败；二维码 + 手动 IP 必须是主路径。
14. **扫码库选型**：ML Kit 依赖 GMS，鸿蒙/无 GMS 设备不可用，统一用 ZXing。

---

## 14. 留给实现者的决定

以下不改变产品形态，由实现者自行决定并在实现文档中记录：

- 菜单栏 App 与 Android 连接页的具体布局、文案、图标。
- 码率/画质预设的具体档位与命名。
- 日志与统计浮层的呈现细节。
- Mac 端证书生成与钥匙串存储的具体做法。
- Android 端厂商白名单的初始名单与维护方式。
- 单元测试组织方式与 CI 选型。
- v1.1 输入阶段的手势参数默认值与可配置项。

---

## 15. 待核实清单

本轮调研环境无外网，以下结论来自既有知识与社区资料，**未能在线复核**。开工前用一台联网的开发机按表中方式确认，确认结果回填本文档：

| # | 待核实项 | 验证方式 |
|---|---|---|
| 1 | `CGVirtualDisplay` 在当前 macOS 版本可用、尺寸约束与失败态 | 用 20 行 Swift 探针：创建 → apply → 查 `CGGetActiveDisplayList` 与 `SCShareableContent`；对照 vdisplay/DeskPad |
| 2 | 低延迟码控键的可用版本与传入位置（11.3+，encoder specification） | 查 Apple 文档；创建会话时传入后确认无限 GOP、无 B 帧 |
| 3 | SCK 对虚拟屏的 idle 行为与黑屏条件 | 静止 30 秒、睡眠、锁屏各观察一次 |
| 4 | 各机型厂商低延迟键是否生效或抛异常 | 在平板与手机上逐个 try/catch，对比解码耗时 |
| 5 | 卓易通的 USB accessory / ADB / NSD / 硬解支持 | 真机逐项测试并记录 |
| 6 | AOA 的 16 KiB 块大小、device-speaks-first、USB 3 口重枚举 | 参考 rustscreen/aoakvm，或自写最小探针 |
| 7 | `swift-certificates` 自签 + keychain 身份、免弹窗 | 写最小 NWListener + SSLSocket 互通 demo |
| 8 | TLS 1.2/1.3 在目标 Android 版本上的实际协商结果 | 两台设备各跑一次 `SSLSocket` 握手并打印协议版本 |
| 9 | 1200B 包 + 16B 头在目标 AP 上的实测量化 | 弱网工具 + 码率阶梯，记录丢包与延迟 |
| 10 | 2560×1600@60 在平板上的硬解延迟与内部缓冲帧数 | 调试浮层打点 + 光子到光子测试 |

**验证进度（2026-11-13）：**

- #1 **通过**：macOS 27.2.1 创建 2560×1600@60 HiDPI 虚拟屏成功并 online。
- #2 **通过**：低延迟码控会话创建成功；30 帧仅 1 个关键帧（无限 GOP）；`MaxFrameDelayCount` 不支持（-12900）。
- #3 **通过**：SCK 对虚拟屏持续回调；8.5 秒静置得到 264 个 `.idle`、65 个 `.complete`，仅 64 个带非空脏矩形；帧间隔最大 38ms。编码条件定为「`.complete` + 非空脏矩形」，每秒保活。另确认捕获尺寸必须用 `CGDisplayMode.pixelWidth/Height`，否则 HiDPI 虚拟屏会降采样。
- #4/#5/#6/#8/#10 **后置为实现期验证**：这些项需要最小可运行 APK 与真机，作为 M1/M3 的退出标准，不阻塞设计定稿；连接设备并开启 adb 后可先做机型信息与解码能力探测。
- #7 **待实现阶段**：`swift-certificates` 需联网拉取依赖，当前环境无外网；先用 openssl 生成的等价证书验证 TLS 协商，框架代码在 M0 联调时验证。
- #9 **待 Wi-Fi 环境**：需要 5GHz AP 与两台设备。

---

## 16. 实现与验收现状（2026-11-14）

**已交付（M0–M2）：**

- M0：协议 v1、共享测试向量、mock server/client、Mac 捕获/编码 CLI。
- M1：Android 解码显示（SurfaceView）、逐帧统计、丢帧后关键帧恢复、自动重连；开发期使用 `adb reverse`。
- M2：`CGVirtualDisplay` 扩展屏、设备旋转/分辨率自适应（helper 通过 `execv` 重建虚拟屏）、菜单栏 App 与独立主窗口、内嵌实时日志。
- Android 控制面板位于屏幕右侧，含设置、调试开关、断开；调试浮层显示 decode/e2e/rtt 延迟（ms）。

**真机验收（vivo V2309A，Android 16，MediaTek）：**

- 硬解 `c2.mtk.avc.decoder hardware=true`；2800×1260@60 动态画面实测 49 fps、decode 20 ms、e2e 29 ms、RTT 2 ms、drop 0；Mac 编码约 8–10 ms。
- 验证通过：连接、断开/重连、横竖屏重建（1260×2800 / 2800×1260）、右侧面板、调试开关、屏幕常亮、helper 停止后自动恢复、Mac 状态栏常驻与单实例主窗口、日志时间戳与自动滚动。
- 模拟器（软件解码）用于回归 UI 与恢复流程；真机用于性能与硬解验收。

**与完整 v1.0 验收标准的差距：**

- 仍使用 `adb reverse`，AOA 免调试 USB 未实现；TCP 明文 + 无 TLS；Wi-Fi/5GHz 路径未实现。
- 未做 2 小时稳定性与内存增长测试；平板性能基准尚未单独验收。
- 上述差距作为后续里程碑，不阻塞当前 M0–M2 显示链路验收。

---

## 附：与前版方案的差异

| 项 | 前版 | 本版 | 原因 |
|---|---|---|---|
| 范围 | 显示 + 触控 + 手写笔一次交付 | v1.0 只做显示，输入后置 | 用户决定：先跑通 MVP |
| 共享核心 | C++ `libmirage-core` 三端复用 | 不引入，Swift/Kotlin 各自实现 | 只有两个平台；协议靠测试向量对齐 |
| 加密 | Noise/自研 AEAD | TLS 1.2+ + 证书固定；AOA v1.0 明文 | 两端系统库直接支持，少写自研密码学 |
| 协议 | 流 + 数据报双模 | v1.0 仅流模式，UDP 推迟到 Wi-Fi | 有线优先，先交付能用的 |
| Mac 硬件 | Apple Silicon + Intel | 仅 Apple Silicon | 用户决定 |
| 手写笔 | 压感为一等公民 | CGEvent 尽力而为，v1.2 再评估虚拟 HID | 用户决定 |
| 鸿蒙 | 原生 ArkTS 版 | 卓易通跑 APK，原生后置 | 用户决定 |
| 编解码 | H.264/HEVC 并重 | H.264 默认，HEVC 可选 | 兼容性与解码延迟 |