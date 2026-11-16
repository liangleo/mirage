# Mirage M5 实施计划（v1.1 输入回传：触控、键盘、手写笔）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在显示链路上增加输入回传：Android 触控/手势/键盘/手写笔 → Mac CGEvent 注入，做到可日常操作扩展屏且断连不卡键。

**Architecture:** 输入复用现有 USB/TCP/TLS 可靠字节流；Android 采集 `MotionEvent`/`KeyEvent`/IME 提交文本，归一化坐标后发 INPUT/KEY/TEXT/SCROLL；Mac Session 解析为 `InputEvent`，经权限/配对/暂停门禁后交给 `InputInjector`，映射到虚拟显示器全局坐标并调用 CGEvent。输入只在已配对会话生效，Wi-Fi 明文不开放。

**Tech Stack:** Swift 6 / CoreGraphics / ApplicationServices / AppKit；Kotlin / Android MotionEvent / InputConnection / Compose；两端共享 `protocol/vectors.json`。

**Spec:** `docs/superpowers/specs/2026-11-14-mirage-input-design.md`；主设计 §5.5、§9、§10、§11。

## Global Constraints

- 触控绝对定位，坐标相对视频内容区（去黑边），Mac 端 clamp 到虚拟显示器 `CGDisplayBounds`。
- 单击延迟到手势确定后再发送；双指不产生点击；手写笔按下立即发送。
- 断开、暂停、旋转、切换分辨率、helper 退出时必须释放所有鼠标键和键盘键。
- 输入只在已配对、已授权、未暂停的会话生效；Wi-Fi 明文会话一律不启用。
- Mac 键盘注入需要辅助功能权限；安全输入模式下拒绝键盘注入并提示。
- 实体键盘可打印字符走 KEY（带 unicode）；软键盘已提交文本走 TEXT；不得重复输入。
- 输入事件限速 500 次/秒；指针 move 合并到最多 120Hz；队列满丢旧 move，不阻塞视频。
- 执行时不自动提交；每个任务验证通过、用户确认后再提交代码。

## Review Focus

1. **断连卡键**：按住 Cmd/Shift 或鼠标左键时拔线，Mac 必须释放；重连后不能残留按下状态。
2. **触摸误点击**：第一根手指落下后第二根加入，不能先产生一次左键单击；第二指加入要 cancel 当前拖动。
3. **坐标偏移**：黑边、旋转、副屏在左（负 origin）时点击位置必须准确；越界 clamp 到虚拟屏。
4. **IME 重复/丢字**：中文候选阶段不发送，commitText 只发一次；实体键盘不额外发 TEXT。
5. **权限失败**：辅助功能未授权、被撤销、安全输入模式时，不能静默丢弃；UI 要有状态和原因。
6. **边缘手势冲突**：右侧手柄区域不能被 InputView 吃掉；系统返回手势不能误触发。
7. **输入攻击面**：未配对设备、暂停状态、畸形帧、超大文本、NaN 坐标必须被拒绝；日志不记录按键内容。

---

## 文件结构

```
mac/Sources/MirageCore/
  InputMessages.swift          # INPUT/KEY/TEXT/SCROLL 编解码与 InputEvent
  Messages.swift               # SESSION_CONFIG input_caps、CTRL code 扩展
  Protocol.swift               # MessageType 9/10/11

mac/Sources/MirageHelper/
  InputInjector.swift          # 鼠标/键盘/手写笔注入、释放所有、权限
  MirageServer.swift           # 输入门禁、CTRL、input_caps
  Session.swift                # 解析输入并产出 .inject(InputEvent)

mac/Sources/MirageMenu/MirageMenuApp.swift  # 权限状态、暂停输入、设备授权

android/app/src/main/java/app/mirage/
  net/InputMessages.kt         # 与 Swift 对齐的编解码
  net/MirageClient.kt          # sendInput(...)
  input/InputController.kt     # 采集 + 发送 + 生命周期
  input/GestureMapper.kt       # 纯状态机，可单测
  input/InputView.kt           # 透明触摸层、触点提示
  input/KeyboardBridge.kt      # IME/实体键盘
  MainActivity.kt              # 输入开关、键盘按钮、内容区
  ui/VideoView.kt              # 暴露内容区 rect

protocol/vectors.json          # 输入消息测试向量
```

---

## Task 1：输入协议与测试向量

**Files:**
- Create: `mac/Sources/MirageCore/InputMessages.swift`
- Create: `android/app/src/main/java/app/mirage/net/InputMessages.kt`
- Modify: `mac/Sources/MirageCore/Protocol.swift`
- Modify: `android/app/src/main/java/app/mirage/net/Protocol.kt`
- Modify: `mac/Sources/MirageCore/Messages.swift`
- Modify: `protocol/README.md`
- Modify: `protocol/vectors.json`
- Test: `mac/Tests/MirageCoreTests/InputMessageTests.swift`
- Test: `android/app/src/test/java/app/mirage/net/InputMessageTest.kt`

**Interfaces:**

`MessageType` 追加 `key = 9`、`text = 10`、`scroll = 11`。INPUT（0x04）沿用 32 字节布局，`kind` 1 down / 2 move / 3 up / 4 cancel / 5 hover。

KEY（0x09，18 字节）：

```
u8  action        # 1 down, 2 up
u8  modifiers     # bit0 Shift, bit1 Control, bit2 Option, bit3 Command,
                  # bit4 Caps Lock, bit5 Fn
u8  flags         # bit0 repeat, bit1 from IME
u8  reserved
u16 keycode       # Android KeyEvent.keyCode
u32 unicode       # Unicode scalar，0 表示无
u64 ts_us
```

TEXT（0x0A）：

```
u16 byte_len      # UTF-8，1..4096
... UTF-8
u64 ts_us
```

SCROLL（0x0B）：

```
u8  phase         # 1 begin, 2 change, 3 end
u8  flags         # bit0 Command（捏合缩放）, bit1 precise
u16 reserved
f32 dx, f32 dy    # 设备点，+x 右 / +y 下（手指移动方向）
u64 ts_us
```

SESSION_CONFIG 末尾追加 `u8 input_caps`：bit0 指针、bit1 键盘、bit2 文本、bit3 手写笔、bit4 压感、bit5 倾斜。旧实现忽略尾部字节。

CTRL 追加：`2 = release_all`（客户端 → Mac）、`3 = input_enabled`、`4 = input_disabled + reason`（Mac → 客户端）。

Swift：

```swift
public enum PointerKind: UInt8 { case down = 1, move, up, cancel, hover }
public struct PointerSample: Equatable { /* kind, pointerID, buttons, x, y, pressure, tiltX, tiltY, tsMicros */ }
public struct KeyInput: Equatable { /* action, modifiers, flags, keycode, unicode, tsMicros */ }
public struct TextInput: Equatable { /* text: String, tsMicros */ }
public struct ScrollInput: Equatable { /* phase, flags, dx, dy, tsMicros */ }
public enum InputEvent: Equatable { case pointer([PointerSample]), key(KeyInput), text(TextInput), scroll(ScrollInput), releaseAll }
public func encodeInput(_ samples: [PointerSample]) -> Frame
public func decodeInput(_ payload: Data) throws -> [PointerSample]
public func encodeKey(_ key: KeyInput) -> Frame
public func decodeKey(_ payload: Data) throws -> KeyInput
public func encodeText(_ text: TextInput) -> Frame
public func decodeText(_ payload: Data) throws -> TextInput
public func encodeScroll(_ scroll: ScrollInput) -> Frame
public func decodeScroll(_ payload: Data) throws -> ScrollInput
```

Kotlin 对应 `PointerSample`、`KeyInput`、`TextInput`、`ScrollInput` 与 `InputMessages` 的 encode/decode 函数。

- [ ] **Step 1: 写失败测试**

覆盖：
- INPUT 32 字节/点往返；最多 32 点；`kind` 越界、`count=0`、长度不足报错。
- KEY 修饰键/重复/unicode 往返；未知 `action` 报错。
- TEXT 中英文 UTF-8 往返；0/4097 字节报错。
- SCROLL 往返；NaN/Inf 拒绝。
- `input_caps` 追加后，旧 11 字节解码仍成功且 caps=0。
- CTRL `input_disabled` 带 reason 的解析。

Run:
```bash
cd mac && swift test --filter InputMessageTests
cd android && JAVA_HOME=/Library/Java/JavaVirtualMachines/corretto-17.0.18/Contents/Home ./gradlew :app:testDebugUnitTest --tests '*InputMessageTest'
```
Expected: 先 FAIL（类型/消息不存在）。

- [ ] **Step 2: 实现纯函数编解码**

两端只做布局与边界校验；不依赖 Android/Mac 运行时。输入帧上限按现有 8 MiB，但解码器额外限制 count ≤32、TEXT ≤4096，避免分配攻击。

- [ ] **Step 3: 冻结向量**

把 2 点 INPUT、Shift+Cmd 的 KEY、中文 TEXT、一次 scroll begin/change/end 写入 `protocol/vectors.json`；两端读取同一组字段断言。

- [ ] **Step 4: 运行测试**

Run: 同 Step 1。
Expected: 两端 PASS。

---

## Task 2：Mac InputInjector 与辅助功能探针

**Files:**
- Create: `mac/Sources/MirageHelper/InputInjector.swift`
- Modify: `mac/Sources/MirageHelperCLI/main.swift`
- Test: `mac/Tests/MirageHelperTests/InputInjectorTests.swift`

**Interfaces:**

```swift
public final class InputInjector {
    public init(
        displayID: CGDirectDisplayID,
        post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        accessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        nowMicros: @escaping () -> UInt64 = monotonicMicros
    )
    public var isPaused: Bool { get set }
    public func inject(_ event: InputEvent)
    public func releaseAll()
    public static func requestAccessibility()
}
```

- `inject` 先检查 `isPaused`、权限、事件合法性；鼠标坐标用 `CGDisplayBounds(displayID)` 映射并 clamp。
- 鼠标：move/down/up/drag；右键；滚动；双击用 `clickState=2` 尽力识别。
- 键盘：Android keycode → macOS 虚拟键码表；修饰键走 `flagsChanged`；可打印字符优先 `CGEventKeyboardSetUnicodeString`；TEXT 按 UTF-16 分段注入。
- `releaseAll` 释放已记录的鼠标键与键盘键，幂等。
- `MIRAGE_DEBUG` 下可打印事件类型/坐标/耗时，不打印字符内容。
- CLI 新增 `--input-selftest`：打印 `input_accessibility=1/0`、`secure_input=1/0`，退出码 0。

- [ ] **Step 1: 写失败测试**

用注入的 `post` 捕获 CGEvent：
- 归一化 `(0,0)`/`(1,1)` 映射到 `bounds.min/min` 与 `max/max`；越界 clamp。
- down/up 的 `mouseButton` 与 clickState 正确；右键长按不产生左键。
- Cmd+Shift+A 的 flags/keycode 正确；Unicode 文本分段。
- `releaseAll` 对已按下左键/Cmd 发送对应 up/flagsChanged；重复调用不重复发送。
- 权限 false、secureInput true 时键盘不注入；鼠标仍可注入。
- paused 时全部丢弃。

Run: `cd mac && swift test --filter InputInjectorTests`
Expected: FAIL。

- [ ] **Step 2: 实现注入器与探针**

先在 `--input-selftest` 手动确认 helper 的辅助功能归属。若 helper 未继承 Mirage.app 的授权，记录结果并暂停 Task 3 的 UI 接入，改为 helper → 菜单栏 App 回环 IPC 注入（协议不变，单开 Task 2b）。

- [ ] **Step 3: 权限引导与状态**

Mac 菜单栏显示：已授权 / 需要辅助功能 / 安全输入中 / 已暂停。授权按钮打开系统设置「隐私与安全性 → 辅助功能」。授权被撤销时自动暂停并释放所有键。

---

## Task 3：Session/Server 输入门禁

**Files:**
- Modify: `mac/Sources/MirageHelper/Session.swift`
- Modify: `mac/Sources/MirageHelper/MirageServer.swift`
- Modify: `mac/Sources/MirageHelperCLI/HelperApp.swift`
- Test: `mac/Tests/MirageCoreTests/SessionInputTests.swift`

**Interfaces:**
- `SessionAction` 追加 `.inject(InputEvent)`。
- `Session.handle` 解析 INPUT/KEY/TEXT/SCROLL，返回 `.inject`；CTRL code 2 返回 `.inject(.releaseAll)`；畸形输入返回 `[]`，不关闭连接。
- `MirageServer` 暴露：

```swift
public var inputAllowed: ((Data) -> Bool)?      // device_id 是否已授权
public var inputPaused: () -> Bool
public var onInput: ((InputEvent) -> Void)?
public var inputCaps: UInt8                      // 写入 SESSION_CONFIG
```

- 收到 HELLO 记录 `device_id`；只有 `inputAllowed(deviceID) && !inputPaused()` 才调用 `onInput`；否则丢弃并首次发 `CTRL input_disabled`（reason 区分“未授权设备”“已暂停”“明文链路”）。
- 明文 AOA 默认要求本地确认授权；Wi-Fi 未 TLS 时 `inputCaps=0`。

- [ ] **Step 1: 写失败测试**

- `Session` 对合法 INPUT/KEY/TEXT/SCROLL 各返回一个 `.inject`。
- 未知 type、畸形输入返回空且不 close。
- CTRL 2 返回 `.inject(.releaseAll)`。
- `inputAllowed=false` 时 Server 不调用 `onInput`，发送一次 input_disabled。
- `inputCaps` 写入 SESSION_CONFIG 末尾；旧 11 字节解码仍成功。

Run: `cd mac && swift test --filter SessionInputTests`
Expected: FAIL。

- [ ] **Step 2: 实现并接入**

`HelperApp` 创建 `InputInjector`，把 `onInput` 接到注入器；`inputAllowed` 暂时从 UserDefaults 读取已确认 `device_id`，首次弹菜单栏确认。连接关闭/BYE/停止服务时调用 `releaseAll`。

- [ ] **Step 3: 断连释放验证**

Run：连接后按住鼠标/Cmd，拔 USB 或停止服务。
Expected：Mac 不残留按下状态；重连后输入正常。

---

## Task 4：Android 触控采集与手势状态机

**Files:**
- Create: `android/app/src/main/java/app/mirage/input/GestureMapper.kt`
- Create: `android/app/src/main/java/app/mirage/input/InputView.kt`
- Create: `android/app/src/main/java/app/mirage/input/InputController.kt`
- Modify: `android/app/src/main/java/app/mirage/ui/VideoView.kt`
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Modify: `android/app/src/main/java/app/mirage/net/MirageClient.kt`
- Test: `android/app/src/test/java/app/mirage/input/GestureMapperTest.kt`

**Interfaces:**
- `GestureMapper(touchSlopPx: Float = 6dp, longPressMs: Long = 500)`；`onDown/onMove/onUp/onCancel/onHover(event)` 或统一的 `onTouch(event: TouchSample) -> List<InputEvent>`。
- 纯 Kotlin，不依赖 Android 类；`TouchSample(id, x, y, toolType, pressure, tiltX, tiltY, eventTimeMs)`。
- `InputController(client, contentRectProvider, mapper, onLocalTouch)`：发送 INPUT/SCROLL；输入关闭时清空状态并 `release_all`。
- `MirageClient.sendInput(bytes: ByteArray)`：与视频/PING 写同锁；失败按断线处理。
- `VideoView` 暴露内容区 rect（相对窗口）供坐标归一化；`AspectSurfaceView` 已有宽高，补 `contentRect` 计算。
- 右侧 24dp 手柄区不捕获；API 29+ `setSystemGestureExclusionRects`。

- [ ] **Step 1: 写失败测试**

`GestureMapperTest`：
- 单指轻点 → down+up（左键）。
- 单指移动超阈值 → down + move（拖动），up 结束。
- 长按未移动 → 右键 down/up。
- 第一指按下后第二指加入（未超阈值）→ 不产生点击，进入 scroll。
- 拖动中第二指加入 → cancel 当前拖动，再 scroll。
- 双指捏合 → scroll 带 Command flag，phase begin/change/end。
- 手写笔 → 立即 down，压力/倾斜保留。
- 旋转/取消 → cancel 清理，不残留。

Run:
```bash
cd android && ./gradlew :app:testDebugUnitTest --tests '*GestureMapperTest'
```
Expected: FAIL。

- [ ] **Step 2: 实现状态机与触摸层**

`InputView` 透明覆盖视频，`onTouchEvent` 转成 `TouchSample`；历史点合并，单帧最多 32 点；本地画触点圆点。按键/输入关闭时不拦截事件。

- [ ] **Step 3: 接入 UI**

`StreamingScreen` 增加输入开关/键盘按钮；`MainActivity` 把 `input_caps` 传给 UI，caps=0 时隐藏输入入口。输入开启时右侧手柄仍可滑出。

- [ ] **Step 4: 模拟器验证**

Run:
```bash
adb shell input tap 500 500
adb shell input swipe 400 400 700 400 300
adb shell input swipe 500 800 500 400 300
```
Expected：Mac 光标/点击/拖动/滚动生效；黑边和旋转后坐标仍准确。真机由用户统一确认。

---

## Task 5：Android 键盘与 IME

**Files:**
- Create: `android/app/src/main/java/app/mirage/input/KeyboardBridge.kt`
- Modify: `android/app/src/main/java/app/mirage/input/InputController.kt`
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Test: `android/app/src/test/java/app/mirage/input/KeyMappingTest.kt`

**Interfaces:**
- `KeyboardBridge(context, client, onState)`：
  - 不可见 `EditText`，`onCreateInputConnection` 返回自定义 `InputConnection`。
  - `commitText` → TEXT；`setComposingText` 只本地；`deleteSurroundingText` → 退格 KEY；`sendKeyEvent`/回车/方向键 → KEY；`performEditorAction` → 回车。
  - `dispatchKeyEvent` 捕获实体键盘：可打印字符 KEY（带 unicode），导航/快捷键 KEY；不额外 TEXT。
  - 显示/隐藏键盘：`InputMethodManager.showSoftInput/hideSoftInputFromWindow`；`adjustNothing`。
  - 隐藏键盘/输入关闭/Activity 暂停/旋转/断开：发送 `release_all`。
- `KeyMapping`：Android keycode → 发送字段；单测覆盖字母、数字、方向、退格、回车、Esc、Tab、修饰键。

- [ ] **Step 1: 写失败测试**

`KeyMappingTest`：
- 实体键盘 `A` → KEY down/up，unicode=`a`，modifiers 正确。
- Shift+A → modifiers bit0，unicode=`A`。
- Cmd+C → keycode 映射 + Command flag，不发送 TEXT。
- 软键盘 commitText("你好") → 恰好一条 TEXT，无 KEY 重复。
- 退格 3 次 → 3 条 KEY backspace。
- 隐藏键盘 → release_all。

Run: `cd android && ./gradlew :app:testDebugUnitTest --tests '*KeyMappingTest'`
Expected: FAIL。

- [ ] **Step 2: 实现 IME 桥**

`EditText` 不可见、不本地插入文本；用 `InputConnectionWrapper` 返回 true。软键盘覆盖视频不改变布局；输入面板收起时隐藏 IME。

- [ ] **Step 3: 模拟器验证**

Run:
```bash
adb shell input text "hello"
adb shell input keyevent 67   # backspace
adb shell input keyevent 66   # enter
```
Expected：Mac 文本/退格/回车生效；中文输入法提交后整段出现，候选阶段不发送。实体键盘通过 `adb shell input keyevent` 验证快捷键。

---

## Task 6：输入 UI、菜单栏状态与安全门禁

**Files:**
- Modify: `android/app/src/main/java/app/mirage/MainActivity.kt`
- Modify: `android/app/src/main/java/app/mirage/input/InputView.kt`
- Modify: `mac/Sources/MirageMenu/MirageMenuApp.swift`
- Modify: `mac/Sources/MirageHelper/MirageServer.swift`
- Modify: `README.md`

**Interfaces:**
- Android：控制面板「输入」开关、键盘按钮、触点提示、`input_caps=0` 提示；断开/暂停时清状态。
- Mac：菜单栏输入状态、暂停输入、授权辅助功能、设备输入授权（按 `device_id` 持久化）、安全输入提示。
- 安全门禁：未配对/未授权/暂停/明文 Wi-Fi 一律不注入；发送 `CTRL input_disabled` 原因；限速 500/s；拒绝 NaN/Inf、越界坐标、超长文本。

- [ ] **Step 1: 实现 UI 与状态**

Android 面板不遮挡右侧手柄；Mac 菜单栏输入启用时有明显标识。首次设备授权弹窗文案写明“允许此设备控制 Mac”。

- [ ] **Step 2: 安全门禁测试**

Run:
```bash
cd mac && swift test --filter SessionInputTests
```
新增断言：
- 未授权 device_id 不注入。
- paused 不注入。
- 明文 Wi-Fi 的 input_caps=0。
- NaN/Inf 坐标、>4096 字节 TEXT、超速率输入被丢弃，不崩溃。

Expected: PASS。

- [ ] **Step 3: 辅助功能流程**

首次开启输入时请求权限；拒绝后显示“需要辅助功能权限”，点击打开系统设置；授权后无需重启即可生效（或提示重启 helper）。

---

## Task 7：端到端验收与记录

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-11-14-mirage-input-design.md`（验收后统一同步，不在实现中提交）
- Verify: 模拟器 + 真机（用户确认）

- [ ] **Step 1: 模拟器全流程**

启动 Mac helper + 模拟器：
- 单击、拖动、长按右键、双指滚动、捏合缩放。
- 英文/中文输入，退格/回车/方向键，实体键盘快捷键。
- 旋转屏幕、切换分辨率后坐标仍准确。
- 输入开关关闭后触摸不再影响 Mac。

Expected：全部通过；Mac 日志有输入计数，无按键内容。

- [ ] **Step 2: 断连恢复**

按住鼠标/Cmd 时拔 USB、停止服务、暂停输入、切换 Wi-Fi。
Expected：Mac 立即释放所有键；重连后输入正常；无卡键。

- [ ] **Step 3: 性能与安全**

- 输入事件到 Mac 注入 p95：USB ≤10ms、Wi-Fi ≤50ms。
- 触摸到画面反馈 p95：USB ≤100ms、Wi-Fi ≤180ms。
- 未授权设备、明文 Wi-Fi、暂停状态无法注入。
- 连续 2 小时输入无队列/内存增长。

- [ ] **Step 4: 真机确认**

手机 + 平板各跑一遍触控、键盘、手写笔、断连恢复；记录机型/ROM/输入法。真机验收由用户统一执行，未通过项回到对应 Task。