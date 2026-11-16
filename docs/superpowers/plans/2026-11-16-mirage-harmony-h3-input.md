# Mirage 鸿蒙客户端 H3（输入）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 鸿蒙客户端把触摸、鼠标手势、硬件键盘和软键盘 IME 转成 Mirage 输入消息发给 Mac，并遵守服务端 `input_caps` / CTRL 门控，断开或切页时释放所有按键。

**Architecture:** 四层纯 ArkTS 逻辑（可单测）夹在两个平台层之间：`InputProtocol` 负责字节编码，`GestureMapper` / `KeyMapping` / `ImeBridge` 负责语义，`InputGate` 负责门控；平台层是 `InputOverlay`（XComponent 上的触摸层）、`KeyboardDock`（隐藏 TextInput）与 `ControlDrawer`（输入开关/键盘/断开）。`ClientSession` 只在门控允许时写 socket，`releaseAll` 例外。

**Tech Stack:** ArkTS（API 12+ / target 26）、ArkUI `XComponent.onTouch`、`TextInput.onWillInsert/onWillDelete`、`@ohos.multimodalInput.keyCode`、hypium 单元测试、hdc/uitest 模拟器验收。

**Spec:** `docs/superpowers/specs/2026-11-15-mirage-harmony-client-design.md` §9/§10，输入语义见 `docs/superpowers/specs/2026-11-14-mirage-input-design.md`

## Global Constraints

- **不改 Mac 端、Android 端和协议**：`protocol/vectors.json` 已含 input/key/text/scroll 向量，本计划不新增共享改动。
- 输入范围只含指针、键盘、文本、滚动与门控；不含 UDP、USB、旋转重建、橡皮擦（ArkUI `SourceTool` 无擦除信号，笔一律按 STYLUS 发送）。
- ArkTS 严格模式：只用 `class` 与显式类型；不用 `any`、不用结构化对象字面量、不用索引签名。
- 所有输入帧只在 `InputGate.allow()` 为真时发送；`releaseAll()` 只在连接存在时发送，不受本地/服务端开关限制。
- 触摸坐标一律归一化为内容区 `0..1` 并 clamp；时间戳统一用 `Date.now() * 1000`（ArkUI `event.timestamp` 单位不可靠，不使用）。
- `compatibleSdkVersion = 12`；`onWillInsert/onWillDelete` 与 `enablePreviewText` 均为此版本可用。
- 构建与单测以 `harmony/TESTING.md` 为准；基线为 35/35，H3 结束时必须 `Failure: 0, Error: 0`。
- 模拟器串号 `127.0.0.1:5555`；真实 Helper 联调命令：
  `/Applications/Mirage.app/Contents/MacOS/mirage-helper --mode extend --port 7777 --fps 60 --wifi --auto-size --position right`
- **不自动执行 `git commit`；过程文档不随进度提交**，全部验收后由用户统一决定。

## Review Focus

1. **触摸层必须与视频内容区完全重合**：黑边、旋转、config 变化后坐标偏差会让点击整体错位（Task 6）。
2. **IME 组合输入不能重复上屏**：`onWillInsert` 返回 false 取消插入，若预览文本泄漏会出现拼音与汉字重复（Task 7 含 E2E 验证）。
3. **门控竞态**：CTRL `input_disabled` 后仍持续发帧、或恢复后 UI 不更新；恢复时不得残留旧的禁用原因（Task 2 + Task 5）。
4. **右缘手势与输入互斥**：右缘 15% 起滑才呼出抽屉，边界内的普通点击仍要能发送，否则视频右侧无法点击（Task 6）。
5. **断线/切页残留按键**：未发送 `release_all` 会让 Mac 侧的 Command/Shift 卡住，属于安全问题（Task 5 + Task 8）。

---

### Task 1: 输入协议编解码

**Files:**
- Create: `harmony/entry/src/main/ets/core/InputProtocol.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/InputProtocol.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Produces:
  - `enum PointerKind { DOWN=1, MOVE=2, UP=3, CANCEL=4, HOVER=5 }`
  - `class PointerSample { kind: PointerKind; pointerID: number; buttons: number; x: number; y: number; pressure: number; tiltX: number; tiltY: number; tsMicros: number }`（构造函数同字段顺序）
  - `enum KeyAction { DOWN=1, UP=2 }`；`class KeyInput { action; modifiers; flags; keycode; unicode; tsMicros }`
  - `class TextInput { text: string; tsMicros: number }`
  - `enum ScrollPhase { BEGIN=1, CHANGE=2, END=3 }`；`class ScrollFlags { static readonly COMMAND=1; static readonly PRECISE=2 }`
  - `class ScrollInput { phase; flags; dx; dy; tsMicros }`
  - `encodePointerFrame(samples: PointerSample[]): Uint8Array`、`decodePointerFrame(payload: Uint8Array): PointerSample[]`
  - `encodeKeyFrame(key: KeyInput): Uint8Array`、`decodeKeyFrame(payload: Uint8Array): KeyInput`
  - `encodeTextFrame(text: TextInput): Uint8Array`、`decodeTextFrame(payload: Uint8Array): TextInput`
  - `encodeScrollFrame(scroll: ScrollInput): Uint8Array`、`decodeScrollFrame(payload: Uint8Array): ScrollInput`

- [ ] **Step 1: 写失败测试**

`InputProtocol.test.ets` 用 `vectors.json` 里的十六进制原样断言。辅助函数 `hexToBytes`/`toHex`/`concat` 可从 `Protocol.test.ets` 复制（测试文件不共享辅助模块，保持独立）。测试文件需要从 `Protocol` 导入 `FrameDecoder`/`MessageType`/`ProtocolException`，从 `InputProtocol` 导入被测符号。

```ts
const VECTOR_INPUT = '000000430400020100000142c90000434840003f4ccccd3dcccccdbe4ccccd00000019debd01c70200000142cb0000434940003f333333000000000000000000000019debd061e';
const VECTOR_KEY = '000000130901090000001d0000006100007048860ddf79';
const VECTOR_TEXT = '000000140a0009e4bda0e5a5bd61626300000034005f7a85';
const VECTOR_SCROLL = '000000150b010200003fc00000c0100000000000e891bf9908';

it('decodes and re-encodes pointer samples from vectors', 0, () => {
  const decoder = new FrameDecoder();
  decoder.append(hexToBytes(VECTOR_INPUT));
  const frame = decoder.next()!;
  expect(frame.type).assertEqual(MessageType.INPUT);
  const samples = decodePointerFrame(frame.payload);
  expect(samples.length).assertEqual(2);
  expect(samples[0].kind).assertEqual(PointerKind.DOWN);
  expect(Math.abs(samples[0].x - 100.5) < 1e-5).assertTrue();
  expect(Math.abs(samples[0].y - 200.25) < 1e-5).assertTrue();
  expect(Math.abs(samples[0].pressure - 0.8) < 1e-5).assertTrue();
  expect(Math.abs(samples[0].tiltX - 0.1) < 1e-5).assertTrue();
  expect(Math.abs(samples[0].tiltY + 0.2) < 1e-5).assertTrue();
  expect(samples[0].tsMicros).assertEqual(111111111111);
  expect(samples[1].kind).assertEqual(PointerKind.MOVE);
  expect(toHex(encodePointerFrame(samples))).assertEqual(VECTOR_INPUT);
});

it('rejects bad pointer counts', 0, () => {
  let rejected = false;
  try {
    decodePointerFrame(new Uint8Array([0, 0]));
  } catch (e) {
    rejected = e instanceof ProtocolException;
  }
  expect(rejected).assertTrue();
});
```

KEY/TEXT/SCROLL 同样先 decode 再 encode 比对整帧；KEY 断言 `action=1, modifiers=9, keycode=29, unicode=97, tsMicros=123456789012345`；TEXT 断言 `text='你好abc'`、`tsMicros=223344556677`；SCROLL 断言 `phase=1, flags=2, dx=1.5, dy=-2.25, tsMicros=998877665544`。再补一个 TEXT 边界测试：空文本与 4097 字节抛 `ProtocolException`。

- [ ] **Step 2: 运行测试确认失败**

Run: `make test.harmony`
Expected: 编译失败，`InputProtocol` 模块不存在。

- [ ] **Step 3: 实现 `InputProtocol.ets`**

- `u64` 用高低 32 位读写（与 `encodePing` 相同）：`hi = Math.floor(v / 4294967296); lo = v - hi * 4294967296`。
- 编码前校验：samples 1..32、所有 float 有限、TEXT 的 UTF-8 字节 1..4096、scroll dx/dy 有限；失败抛 `ProtocolException`。
- UTF-8 用 `new util.TextEncoder().encodeInto(text)`；解码用 `util.TextDecoder.create('utf-8').decodeToString(bytes)`。
- 返回完整帧（`encodeFrame(MessageType.X, payload)`），与 Android 的 `InputMessages` 语义一致。
- 解码必须严格校验负载长度：INPUT `2 + count*32`，KEY `18`，TEXT `2+len+8`，SCROLL `20`。

- [ ] **Step 4: 运行测试并通过**

Run: `make test.harmony`
Expected: `Failure: 0, Error: 0`，总数增加 5 条以上。

---

### Task 2: 输入门控纯逻辑

**Files:**
- Create: `harmony/entry/src/main/ets/core/InputGate.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/InputGate.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Produces:
  - `class InputGate { reason: string }`
  - `setConnected(v: boolean): void`、`setLocalEnabled(v: boolean): void`、`getLocalEnabled(): boolean`、`getServerEnabled(): boolean`
  - `applyCtrl(code: number, reason: string): void`（3 → 启用并清空 reason；4 → 禁用并记录 reason；其他 code 忽略）
  - `reset(): void`（服务端启用、reason 清空；本地开关保持）
  - `allow(): boolean`（`connected && localEnabled && serverEnabled`）
  - `allowRelease(): boolean`（`connected`）

- [ ] **Step 1: 写失败测试**

```ts
it('requires connection, local and server switches', 0, () => {
  const gate = new InputGate();
  expect(gate.allow()).assertFalse();
  gate.setConnected(true);
  expect(gate.allow()).assertTrue();
  gate.setLocalEnabled(false);
  expect(gate.allow()).assertFalse();
  gate.setLocalEnabled(true);
  gate.applyCtrl(4, '输入已暂停');
  expect(gate.allow()).assertFalse();
  expect(gate.reason).assertEqual('输入已暂停');
  gate.applyCtrl(3, '');
  expect(gate.allow()).assertTrue();
  expect(gate.reason).assertEqual('');
});

it('release_all remains possible while input is disabled', 0, () => {
  const gate = new InputGate();
  gate.setConnected(true);
  gate.applyCtrl(4, '输入已暂停');
  expect(gate.allow()).assertFalse();
  expect(gate.allowRelease()).assertTrue();
  gate.setConnected(false);
  expect(gate.allowRelease()).assertFalse();
});

it('unknown ctrl codes do not change state', 0, () => {
  const gate = new InputGate();
  gate.setConnected(true);
  gate.applyCtrl(99, 'x');
  expect(gate.allow()).assertTrue();
  expect(gate.reason).assertEqual('');
});
```

- [ ] **Step 2: 运行测试确认失败** — Run: `make test.harmony`，Expected: 模块不存在。

- [ ] **Step 3: 实现 `InputGate.ets`** — 三个布尔字段 + `reason`，方法如上；不依赖 socket/UI。

- [ ] **Step 4: 运行测试并通过** — Run: `make test.harmony`，Expected: `Failure: 0, Error: 0`。

---

### Task 3: 手势语义（GestureMapper 直译）

**Files:**
- Create: `harmony/entry/src/main/ets/input/GestureMapper.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/GestureMapper.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Consumes: `PointerKind`, `PointerSample`, `ScrollInput`, `ScrollPhase`, `ScrollFlags`（Task 1）。
- Produces:
  - `enum TouchTool { FINGER, STYLUS, ERASER }`
  - `enum TouchAction { DOWN, MOVE, UP, POINTER_DOWN, POINTER_UP, CANCEL, HOVER_ENTER, HOVER_MOVE, HOVER_EXIT }`
  - `class TouchSample { id; x; y; tool; buttons; pressure; tiltX; tiltY }`（构造函数带默认值：`tool=FINGER, buttons=1, pressure=1, tiltX=0, tiltY=0`）
  - `class TouchFrame { action: TouchAction; pointers: TouchSample[]; eventTimeMs: number }`
  - `class GestureEvent { pointer: PointerSample[] | null; scroll: ScrollInput | null; static ofPointer(samples): GestureEvent; static ofScroll(scroll): GestureEvent }`
  - `class GestureMapper { constructor(touchSlop: number = 0.01, longPressMs: number = 500); onFrame(frame: TouchFrame): GestureEvent[]; reset(): GestureEvent[] }`

- [ ] **Step 1: 写失败测试**

测试直接用 `TouchSample`/`TouchFrame` 构造序列，断言事件序列：

```ts
it('short tap emits down then up with primary button', 0, () => {
  const mapper = new GestureMapper();
  expect(mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 1000)).length).assertEqual(0);
  const up = mapper.onFrame(new TouchFrame(TouchAction.UP, [], 1100));
  expect(up.length).assertEqual(2);
  expect(up[0].pointer![0].kind).assertEqual(PointerKind.DOWN);
  expect(up[0].pointer![0].buttons).assertEqual(1);
  expect(up[1].pointer![0].kind).assertEqual(PointerKind.UP);
  expect(up[1].pointer![0].buttons).assertEqual(0);
});

it('long press emits secondary click', 0, () => {
  const mapper = new GestureMapper();
  mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
  const up = mapper.onFrame(new TouchFrame(TouchAction.UP, [], 600));
  expect(up[0].pointer![0].buttons).assertEqual(2);
  expect(up[1].pointer![0].buttons).assertEqual(2);
});

it('movement beyond slop turns into a drag', 0, () => {
  const mapper = new GestureMapper();
  mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
  const first = mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.52, 0.5)], 10));
  expect(first.length).assertEqual(2);            // DOWN(origin) + MOVE
  const second = mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.55, 0.5)], 20));
  expect(second.length).assertEqual(1);           // MOVE only
  expect(second[0].pointer![0].x).assertEqual(0.55);
  const up = mapper.onFrame(new TouchFrame(TouchAction.UP, [p(0, 0.55, 0.5)], 30));
  expect(up[0].pointer![0].kind).assertEqual(PointerKind.UP);
});

it('movement inside slop is ignored', 0, () => {
  const mapper = new GestureMapper();
  mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
  expect(mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.505, 0.5)], 10)).length).assertEqual(0);
});

it('two-finger move emits precise scroll with centroid delta', 0, () => {
  const mapper = new GestureMapper();
  mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.3, 0.5)], 0));
  const begin = mapper.onFrame(new TouchFrame(TouchAction.POINTER_DOWN, [p(0, 0.3, 0.5), p(1, 0.5, 0.5)], 10));
  expect(begin.length).assertEqual(1);
  expect(begin[0].scroll!.phase).assertEqual(ScrollPhase.BEGIN);
  expect(begin[0].scroll!.flags).assertEqual(ScrollFlags.PRECISE);
  const change = mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.31, 0.5), p(1, 0.51, 0.5)], 20));
  expect(change[0].scroll!.phase).assertEqual(ScrollPhase.CHANGE);
  expect(change[0].scroll!.dy).assertEqual(0);    // 纵向质心不变
  expect(Math.abs(change[0].scroll!.dx - 10) < 1e-4).assertTrue();
  const end = mapper.onFrame(new TouchFrame(TouchAction.POINTER_UP, [p(0, 0.31, 0.5)], 30));
  expect(end[0].scroll!.phase).assertEqual(ScrollPhase.END);
});
```

另补：捏合（两指间距变化 10% → `flags === COMMAND|PRECISE`、`dx===0`、`dy≈(spread-last)*400`）、三指 `POINTER_DOWN` 不产生滚动、笔 `DOWN` 立即发送、手指 `HOVER_MOVE` 不发事件而笔 `HOVER_MOVE` 发 `PointerKind.HOVER`。

- [ ] **Step 2: 运行测试确认失败** — Run: `make test.harmony`。

- [ ] **Step 3: 实现 `GestureMapper.ets`**

按 Android `GestureMapper.kt` 逐分支移植，状态机 `IDLE/TENTATIVE/DRAG/SCROLL/STYLUS/IGNORE` 与字段（`down`、`downTime`、`lastDrag`、`lastCentroid`、`lastSpread`、`scrollStarted`）一一对应。差异只有两处：

- 事件用 `GestureEvent.ofPointer([sample])` / `GestureEvent.ofScroll(scroll)` 包装。
- `tsMicros` 用 `sample` 外部传入的时间换算：`pointer(...)` 里写 `tsMicros: frame.eventTimeMs * 1000`（`pointer` 需要接收 `tsMicros` 参数，因为 `TouchSample` 不再带 `eventTimeMs`）；滚动事件用 `Date.now() * 1000`。

`metrics` 用 `Math.hypot` 求两指间距；滚动灵敏度沿用 `dx*1000`、`dy*1000`、捏合 `dy=(spread-lastSpread)*400`，捏合阈值 `|Δspread|/lastSpread > 0.02`。

- [ ] **Step 4: 运行测试并通过** — Run: `make test.harmony`，Expected: `Failure: 0, Error: 0`。

---

### Task 4: 键盘映射与修饰键跟踪

**Files:**
- Create: `harmony/entry/src/main/ets/input/KeyMapping.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/KeyMapping.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Consumes: `KeyInput`, `KeyAction`（Task 1）。
- Produces:
  - `class InputModifiers { static readonly SHIFT=1; CONTROL=2; OPTION=4; COMMAND=8; CAPS_LOCK=16; FN=32 }`
  - `androidKeycode(harmonyKey: number): number`（未知返回 0）
  - `unicodeFor(androidKey: number, modifiers: number): number`（0 表示无字符）
  - `class ModifierTracker { update(harmonyKey: number, down: boolean): number; reset(): void; capsLocked: boolean }`

- [ ] **Step 1: 写失败测试**

```ts
it('maps harmony keycodes to android keycodes', 0, () => {
  expect(androidKeycode(2017)).assertEqual(29);   // A
  expect(androidKeycode(2042)).assertEqual(54);   // Z
  expect(androidKeycode(2000)).assertEqual(7);    // 0
  expect(androidKeycode(2043)).assertEqual(55);   // comma
  expect(androidKeycode(2054)).assertEqual(66);   // enter
  expect(androidKeycode(2055)).assertEqual(67);   // backspace
  expect(androidKeycode(2012)).assertEqual(19);   // dpad up
  expect(androidKeycode(2072)).assertEqual(113);  // ctrl left
  expect(androidKeycode(2090)).assertEqual(131);  // F1
  expect(androidKeycode(2101)).assertEqual(142);  // F12
  expect(androidKeycode(9999)).assertEqual(0);
});

it('derives unicode from android keycode and modifiers', 0, () => {
  expect(unicodeFor(29, 0)).assertEqual(97);                  // a
  expect(unicodeFor(29, InputModifiers.SHIFT)).assertEqual(65); // A
  expect(unicodeFor(29, InputModifiers.CAPS_LOCK)).assertEqual(65);
  expect(unicodeFor(7, InputModifiers.SHIFT)).assertEqual(33); // !
  expect(unicodeFor(69, 0)).assertEqual(45);                  // -
  expect(unicodeFor(62, 0)).assertEqual(32);                  // space
});

it('tracks modifiers and caps lock across events', 0, () => {
  const tracker = new ModifierTracker();
  expect(tracker.update(2047, true)).assertEqual(InputModifiers.SHIFT);   // shift down
  expect(tracker.update(2072, true)).assertEqual(InputModifiers.SHIFT | InputModifiers.CONTROL);
  expect(tracker.update(2047, false)).assertEqual(InputModifiers.CONTROL);
  expect(tracker.update(2074, true)).assertEqual(InputModifiers.CONTROL | InputModifiers.CAPS_LOCK);
  expect(tracker.update(2074, true)).assertEqual(InputModifiers.CONTROL);  // caps toggles off
  tracker.reset();
  expect(tracker.update(9999, true)).assertEqual(0);
});
```

- [ ] **Step 2: 运行测试确认失败** — Run: `make test.harmony`。

- [ ] **Step 3: 实现 `KeyMapping.ets`**

映射表用 `Map<number, number>` 一次性构建（Harmony 键码 → Android 键码）：

- 字母 `2017..2042` → `29 + (k - 2017)`；数字 `2000..2009` → `7 + (k - 2000)`；F1..F12 `2090..2101` → `131 + (k - 2090)`。
- 标点：`2043→55, 2044→56, 2056→68, 2057→69, 2058→70, 2059→71, 2060→72, 2061→73, 2062→74, 2063→75, 2064→76`。
- 控制键：`2049→61(Tab), 2050→62(Space), 2054→66(Enter), 2055→67(Del), 2071→112(ForwardDel), 2070→111(Escape)`。
- 方向/导航：`2012→19, 2013→20, 2014→21, 2015→22, 2081→122(Home), 2082→123(End), 2068→92(PageUp), 2069→93(PageDown)`。
- 修饰键：`2045→57, 2046→58, 2047→59, 2048→60, 2072→113, 2073→114, 2076→117, 2077→118, 2074→115`。
- 不映射 `KEYCODE_BACK(2)`、音量键（16/17/23）。

`unicodeFor` 按 Android 键码区间重写 `KeyMapping.kt` 的逻辑（29..54 字母、7..16 数字、55/56/68..76 标点、62 空格），shift 与 caps 判定保持 `shifted != caps`。

`ModifierTracker` 维护 Shift/Ctrl/Option/Command 的左右键计数与 Caps 布尔翻转；`update` 先更新状态再返回位掩码。

- [ ] **Step 4: 运行测试并通过** — Run: `make test.harmony`。

---

### Task 5: 会话层输入 API 与门控接入

**Files:**
- Modify: `harmony/entry/src/main/ets/core/InputProtocol.ets`（新增 CTRL 编解码）
- Modify: `harmony/entry/src/ohosTest/ets/test/InputProtocol.test.ets`（新增 CTRL 用例）
- Modify: `harmony/entry/src/main/ets/core/ClientSession.ets`
- Modify: `harmony/entry/src/main/ets/core/Runtime.ets`
- Modify: `harmony/entry/src/main/ets/pages/ConnectPage.ets`

**Interfaces:**
- Consumes: Task 1 编解码、Task 2 `InputGate`。
- Produces（`ClientSession`）：
  - `sendPointer(samples: PointerSample[]): void`
  - `sendKey(key: KeyInput): void`
  - `sendText(text: TextInput): void`
  - `sendScroll(scroll: ScrollInput): void`
  - `releaseAll(): void`
  - `setInputEnabled(enabled: boolean): void`
  - `isInputEnabled(): boolean`
  - `SessionListener.onInputGate(enabled: boolean, reason: string): void`
- Produces（`InputProtocol`）：`enum CtrlCode { REQUEST_KEYFRAME=1, RELEASE_ALL=2, INPUT_ENABLED=3, INPUT_DISABLED=4 }`、`class CtrlMessage { code: number; reason: string }`、`decodeCtrl(payload): CtrlMessage`、`encodeCtrl(code: number, reason?: string): Uint8Array`
- Produces（`Runtime`）：`onInputGate: (enabled: boolean, reason: string) => void`
- Produces（HELLO）：`hello.features = 0x70`（bit4 指针 / bit5 键盘 / bit6 IME）

- [ ] **Step 1: 写 CTRL 编解码失败测试**

```ts
it('encodes and decodes ctrl messages', 0, () => {
  expect(toHex(encodeCtrl(CtrlCode.RELEASE_ALL))).assertEqual('000000020602');
  const payload = encodeCtrl(CtrlCode.INPUT_DISABLED, '输入已暂停').slice(5);
  const decoded = decodeCtrl(payload);
  expect(decoded.code).assertEqual(CtrlCode.INPUT_DISABLED);
  expect(decoded.reason).assertEqual('输入已暂停');
  expect(decodeCtrl(new Uint8Array([99])).code).assertEqual(99);
});

it('rejects truncated ctrl reasons', 0, () => {
  let rejected = false;
  try {
    decodeCtrl(new Uint8Array([4, 10, 1, 2]));
  } catch (e) {
    rejected = e instanceof ProtocolException;
  }
  expect(rejected).assertTrue();
});
```

- [ ] **Step 2: 运行测试确认失败** — Run: `make test.harmony`。

- [ ] **Step 3: 实现 CTRL 编解码**

`encodeCtrl`：`payload = [code]`；当 `reason` 非空时追加 `u8 len + UTF-8`（len > 255 抛错）。`decodeCtrl`：空负载抛错；`code===4` 时要求 `payload[1]` 存在且 `2+len === payload.length`，UTF-8 解码；其余 code 忽略尾部字节。

- [ ] **Step 4: 接入 `ClientSession`**

- 字段 `private gate: InputGate = new InputGate()`；`requestKeyframe()` 改用 `this.send(encodeCtrl(CtrlCode.REQUEST_KEYFRAME))`。
- `openTransport().then(...)` 成功后 `this.gate.setConnected(true)`；`closeTransport()` 里 `this.gate.setConnected(false)`。
- `handleFrame` 新增 `MessageType.CTRL` 分支：`const ctrl = decodeCtrl(frame.payload)`；code 3/4 调 `this.gate.applyCtrl(code, ctrl.reason)` 并 `this.listener.onInputGate(this.gate.allow(), ctrl.reason)`。CTRL 解码失败只记 `hilog.warn`，不断线。
- `onConfig` 时 `this.gate.reset()` 并通知监听者 `onInputGate(this.gate.allow(), '')`。
- 新公开方法：
  - `sendPointer/sendKey/sendText/sendScroll`：`if (!this.gate.allow()) return;` 然后 `this.send(...)`；`sendText` 内部 `try/catch ProtocolException` 后 `hilog.warn` 丢弃（超长/空文本）。
  - `releaseAll()`：`if (this.gate.allowRelease()) this.send(encodeCtrl(CtrlCode.RELEASE_ALL));`
  - `setInputEnabled(enabled)`：`this.gate.setLocalEnabled(enabled); if (!enabled) this.releaseAll();`
  - `isInputEnabled()`：`return this.gate.allow();`
- `stop()` 在关闭传输前先 `this.releaseAll()`（best-effort）。

- [ ] **Step 5: `Runtime` 与 `ConnectPage`**

- `Runtime` 增加 `static onInputGate: (enabled: boolean, reason: string) => void` 默认空函数，`reset()` 里恢复默认。
- `ConnectPage.UiListener` 构造函数增加第 4 个回调 `gateCb`，实现 `onInputGate(enabled, reason)` → `Runtime.onInputGate(enabled, reason)`。
- `ConnectPage.init()` 里设置 `this.hello.features = 0x70;`。

- [ ] **Step 6: 运行测试与编译** — Run: `make test.harmony`，Expected: `Failure: 0, Error: 0`；HAP 编译通过。

---

### Task 6: 内容区几何、触摸采集与右缘手势

**Files:**
- Create: `harmony/entry/src/main/ets/input/InputGeometry.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/InputGeometry.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`
- Create: `harmony/entry/src/main/ets/ui/InputOverlay.ets`
- Modify: `harmony/entry/src/main/ets/ui/VideoSurface.ets`
- Modify: `harmony/entry/src/main/ets/pages/StreamPage.ets`

**Interfaces:**
- Consumes: Task 3 `GestureMapper`/`GestureEvent`/`TouchFrame`/`TouchSample`。
- Produces:
  - `class ContentRect { width: number; height: number }`
  - `fitContent(containerWidth, containerHeight, videoWidth, videoHeight): ContentRect`（取整，容器无效返回 0×0）
  - `class Point { x: number; y: number }`、`normalizePoint(xVp, yVp, widthVp, heightVp): Point`（clamp 0..1）
  - `const EDGE_FRACTION = 0.15`、`const EDGE_SWIPE_VP = 40`
  - `isEdgeStart(xVp, widthVp): boolean`、`isEdgeSwipe(startXVp, widthVp, currentXVp): boolean`
  - `InputOverlay` 组件 props：`contentWidth/contentHeight`、`onEvents: (events: GestureEvent[]) => void`、`onOpenDrawer: () => void`
  - `VideoSurface` 新 prop：`onContentRect: (rect: ContentRect) => void`

- [ ] **Step 1: 写几何失败测试**

```ts
it('fits video into container preserving aspect ratio', 0, () => {
  const a = fitContent(1000, 1000, 16, 9);
  expect(a.width).assertEqual(1000);
  expect(a.height).assertEqual(562);
  const b = fitContent(1000, 500, 4, 3);
  expect(b.width).assertEqual(666);
  expect(b.height).assertEqual(500);
  const none = fitContent(0, 500, 16, 9);
  expect(none.width).assertEqual(0);
});

it('normalizes and clamps touch coordinates', 0, () => {
  const p = normalizePoint(150, 250, 300, 500);
  expect(p.x).assertEqual(0.5);
  expect(p.y).assertEqual(0.5);
  expect(normalizePoint(-10, 600, 300, 500).x).assertEqual(0);
  expect(normalizePoint(-10, 600, 300, 500).y).assertEqual(1);
});

it('classifies right-edge swipe without eating inner taps', 0, () => {
  expect(isEdgeStart(870, 1000)).assertTrue();   // 85% 起
  expect(isEdgeStart(800, 1000)).assertFalse();
  expect(isEdgeSwipe(900, 1000, 850)).assertTrue();
  expect(isEdgeSwipe(900, 1000, 880)).assertFalse();
  expect(isEdgeSwipe(800, 1000, 700)).assertFalse();
});
```

- [ ] **Step 2: 运行测试确认失败** — Run: `make test.harmony`。

- [ ] **Step 3: 实现 `InputGeometry.ets`**

`fitContent` 用 `Math.min(cw/vw, ch/vh)` 后 `Math.floor`；`normalizePoint` 除零返回 `{x:0,y:0}`；`isEdgeStart` 为 `x >= width * 0.85`；`isEdgeSwipe` 为 `isEdgeStart(startX, width) && (startX - currentX) >= 40`。

- [ ] **Step 4: `VideoSurface` 复用 `fitContent` 并上报内容区**

把 `fit()` 内的等比计算替换为 `fitContent(...)`；当新宽高与旧值不同时调用 `this.onContentRect(rect)`。保持默认 prop 为空函数。

- [ ] **Step 5: 实现 `InputOverlay.ets`**

根节点 `Stack().width(this.contentWidth).height(this.contentHeight).onTouch(...)`，只负责采集与转发：

- `TouchType.Down`：记录 `edgeStartX = first.x`；`isEdgeStart` 为真则 `suppress = true` 并返回（不转发）。
- `TouchType.Move` 且 `suppress`：`isEdgeSwipe` 为真时调 `onOpenDrawer()`，继续返回直到抬起。
- `TouchType.Up/Cancel`：`suppress = false`。
- 动作映射：`Down` → 多指时 `POINTER_DOWN` 否则 `DOWN`；`Move` → `MOVE`；`Up` → 仍有触点时 `POINTER_UP` 否则 `UP`；`Cancel` → `CANCEL`。
- 触点来源：`UP/CANCEL` 用 `event.changedTouches`，其余用 `event.touches`。
- 每个触点：`normalizePoint(t.x, t.y, contentWidth, contentHeight)`；`tool = event.sourceTool === SourceTool.Pen ? TouchTool.STYLUS : TouchTool.FINGER`；`pressure = t.pressure ?? 1`；`tiltX/tiltY = clamp(event.tiltX / 90, -1, 1)`。
- `eventTimeMs = Date.now()`；`const events = this.mapper.onFrame(frame); if (events.length > 0) this.onEvents(events);`

- [ ] **Step 6: `StreamPage` 接入**

- 新状态：`@State contentW = 0`、`@State contentH = 0`。
- `VideoSurface` 传入 `onContentRect: (rect) => { this.contentW = rect.width; this.contentH = rect.height; }`。
- Stack 中在 `VideoSurface` 之后、统计浮层之前放 `InputOverlay`，本任务先以 `contentW > 0 && (Runtime.config.inputCaps & 0x01) !== 0` 为渲染条件；Task 8 改为完整的 `inputActive` 表达式。
- `onEvents` 逐条分发：`event.pointer !== null` → `session.sendPointer(event.pointer)`；`event.scroll !== null` → `session.sendScroll(event.scroll)`。

- [ ] **Step 7: 运行测试与编译** — Run: `make test.harmony`，Expected: `Failure: 0, Error: 0`；HAP 编译通过。

---

### Task 7: IME 桥（软键盘与硬件键盘）

**Files:**
- Create: `harmony/entry/src/main/ets/input/ImeBridge.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/ImeBridge.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`
- Create: `harmony/entry/src/main/ets/ui/KeyboardDock.ets`
- Modify: `harmony/entry/src/main/ets/pages/StreamPage.ets`

**Interfaces:**
- Consumes: Task 4 `androidKeycode`/`unicodeFor`/`ModifierTracker`、Task 1 `KeyInput`。
- Produces:
  - `enum ImeCommandKind { TEXT, DELETE }`
  - `class ImeCommand { kind: ImeCommandKind; text: string; count: number }`
  - `class ImeBridge { insertCommands(value: string): ImeCommand[]; deleteCommands(count: number): ImeCommand[] }`
  - `KeyboardDock` 组件 props：`enabled: boolean`、`onText: (text: string) => void`、`onDelete: (count: number) => void`
  - `StreamPage` 公开内部方法：`onHardwareKey(event: KeyEvent): void`（根节点与 TextInput 共用）

- [ ] **Step 1: 写 ImeBridge 失败测试**

```ts
it('turns committed text into a text command', 0, () => {
  const bridge = new ImeBridge();
  const cmds = bridge.insertCommands('你好');
  expect(cmds.length).assertEqual(1);
  expect(cmds[0].kind).assertEqual(ImeCommandKind.TEXT);
  expect(cmds[0].text).assertEqual('你好');
  expect(bridge.insertCommands('').length).assertEqual(0);
});

it('turns deletions into one delete command with a count', 0, () => {
  const bridge = new ImeBridge();
  const cmds = bridge.deleteCommands(2);
  expect(cmds.length).assertEqual(1);
  expect(cmds[0].kind).assertEqual(ImeCommandKind.DELETE);
  expect(cmds[0].count).assertEqual(2);
  expect(bridge.deleteCommands(0).length).assertEqual(0);
});
```

- [ ] **Step 2: 运行测试确认失败** — Run: `make test.harmony`。

- [ ] **Step 3: 实现 `ImeBridge.ets`** — 纯函数式类，不依赖 UI；文本为空返回 `[]`，删除数量 ≤0 返回 `[]`。

- [ ] **Step 4: 实现 `KeyboardDock.ets`**

```ts
TextInput({ text: '' })
  .id('mirageKb')
  .width(1)
  .height(1)
  .opacity(0.01)
  .caretColor(Color.Transparent)
  .enablePreviewText(false)
  .onWillInsert((info: InsertValue) => {
    if (this.enabled) {
      const cmds = this.bridge.insertCommands(info.insertValue);
      for (const cmd of cmds) this.onText(cmd.text);
    }
    return false;
  })
  .onWillDelete((info: DeleteValue) => {
    if (this.enabled) {
      const cmds = this.bridge.deleteCommands(info.deleteValue.length);
      for (const cmd of cmds) this.onDelete(cmd.count);
    }
    return false;
  })
  .onSubmit(() => {
    if (this.enabled) this.onText('\n');
  })
```

- [ ] **Step 5: `StreamPage` 键盘接线**

- 状态：`@State keyboardOn = false`。
- 根 `Stack` 增加 `.focusable(true).defaultFocus(true).onKeyEvent((event: KeyEvent) => this.onHardwareKey(event))`。
- `KeyboardDock({ enabled: this.keyboardOn && inputActive, onText: (t) => session.sendText(new TextInput(t, Date.now() * 1000)), onDelete: (n) => { for (let i = 0; i < n; i++) { session.sendKey(delKey(KeyAction.DOWN)); session.sendKey(delKey(KeyAction.UP)); } } })`，其中 `delKey(action)` 返回 `new KeyInput(action, 0, 0, 67, 0, Date.now() * 1000)`（Android `KEYCODE_DEL`）。
- `onHardwareKey`：
  - `event.type` 不是 `KeyType.Down/Up` 直接返回；
  - 忽略 `2(Back)`、`16/17/23`（音量）；
  - `const modifiers = tracker.update(event.keyCode, down)`；
  - `const code = androidKeycode(event.keyCode)`；`code === 0` 返回；
  - `const unicode = event.unicode !== undefined ? event.unicode : unicodeFor(code, modifiers)`；
  - `session.sendKey(new KeyInput(down ? KeyAction.DOWN : KeyAction.UP, modifiers, 0, code, unicode, Date.now() * 1000))`。
- 分发守卫（避免重复发送）：根 `Stack` 的 `onKeyEvent` 仅在 `!this.keyboardOn` 时调用 `onHardwareKey`；`KeyboardDock` 的 `TextInput` 自带 `onKeyEvent`，键盘打开时只转发方向/删除/Esc/Tab 等非字符键，并在转发后 `event.stopPropagation()`，字母/数字/空格交给 IME 文本路径。
- 键盘开：`setTimeout(() => this.getUIContext().getFocusController().requestFocus('mirageKb'), 0)`；键盘关：`this.getUIContext().getFocusController().clearFocus(); session.releaseAll()`。

- [ ] **Step 6: 运行测试与编译** — Run: `make test.harmony`，Expected: `Failure: 0, Error: 0`。

- [ ] **Step 7: 中文输入 E2E 验证（模拟器 + 真实 Helper）**

在 Mac 上打开 TextEdit，客户端连接后打开键盘，执行：

```bash
hdc -t 127.0.0.1:5555 shell uitest uiInput inputText 1440 960 "你好abc"
```

Expected: TextEdit 中出现且只出现一次 `你好abc`；若出现拼音/汉字重复，说明预览文本泄漏，必须修正后再进入 Task 8（可先把 `KeyboardDock` 改为 `onChange` 差量方案并记录原因）。

---

### Task 8: 控制抽屉、状态提示与验收

**Files:**
- Create: `harmony/entry/src/main/ets/ui/ControlDrawer.ets`
- Modify: `harmony/entry/src/main/ets/pages/StreamPage.ets`
- Modify: `harmony/TESTING.md`
- Modify: `docs/superpowers/plans/2026-11-16-mirage-harmony-h3-input.md`（验收记录）

**Interfaces:**
- Consumes: Task 5 `ClientSession.setInputEnabled/releaseAll/isInputEnabled`、`Runtime.onInputGate`；Task 6 `onOpenDrawer`；Task 7 `keyboardOn`。
- Produces: 抽屉组件 props `inputOn: boolean`、`keyboardOn: boolean`、`capsOk: boolean`、`gateEnabled: boolean`、`gateReason: string`，回调 `onToggleInput()`、`onToggleKeyboard()`、`onDisconnect()`、`onClose()`。

- [ ] **Step 1: 实现 `ControlDrawer.ets`**

右侧 260vp 面板（半透明黑底），自下而上：

- `输入` 开关：`capsOk` 为 false 时禁用并显示「服务端未开放输入」；`gateEnabled` 为 false 时显示 `gateReason`（如「输入已暂停」）。
- `键盘` 开关。
- `断开连接`（红字）→ 调 `onDisconnect()`。
- `关闭` → `onClose()`。

- [ ] **Step 2: `StreamPage` 整合**

- 状态：`@State drawerOpen = false`、`@State inputOn = true`、`@State capsOk = true`、`@State gateEnabled = true`、`@State gateReason = ''`。
- `Runtime.onInputGate = (enabled, reason) => { this.gateEnabled = enabled; this.gateReason = reason; }`。
- `onConfig`：`this.capsOk = (config.inputCaps & 0x01) !== 0; this.inputOn = this.capsOk; this.session.setInputEnabled(this.capsOk);`
- `inputActive = this.inputOn && this.capsOk && this.gateEnabled && !this.drawerOpen`；`inputActive` 变化时调 `session.setInputEnabled(inputActive)`（关闭时自动 `releaseAll`）。
- `openDrawer()`：`session.releaseAll(); this.keyboardOn = false; this.drawerOpen = true;`；`closeDrawer()` 反之。
- 右缘把手：宽 14vp、高 80vp、右对齐、半透明，`onClick(openDrawer)`；抽屉打开时隐藏把手。
- `onDisconnect()`：`session.releaseAll(); session.stop(); Runtime.session = null; router.back()`。
- `aboutToDisappear()`：先 `session.releaseAll()` 再 `session.stop()`（保持现有逻辑顺序）；同时把 `Runtime.onInputGate` 恢复为空函数，避免离开页面后回调仍在跑。
- 抽屉与统计浮层共存时，统计浮层保持在左上/右上原位置，抽屉在右侧覆盖。

- [ ] **Step 3: 编译并安装**

```bash
make build.harmony
make install.hap
```

Expected: 安装成功；启动后连接真实 Helper 能出画面。

- [ ] **Step 4: 单指输入 E2E（真实 Helper + 模拟器）**

启动 Helper 后连接 Wi-Fi（TLS 7778），在视频区域执行：

```bash
hdc -t 127.0.0.1:5555 shell uitest uiInput click 1440 960
hdc -t 127.0.0.1:5555 shell uitest uiInput drag 1200 900 1700 900
```

Expected: Helper 日志出现 `input events flowing`；Mac 光标出现对应点击与拖拽（可先在 TextEdit 中选中一段文字验证拖拽方向与坐标无偏移）。点击视频四角与中心各一次，确认无整体偏移。

- [ ] **Step 5: 长按右键 E2E**

在 TextEdit/桌面用一次按住 ≥600ms 再松开的触摸（`uitest uiInput longClick 1440 960`，若该子命令不可用则记录为真机待验）。Expected: Mac 出现右键菜单；Helper 日志显示 `buttons=2` 的 down/up。

- [ ] **Step 6: 双指滚动/捏合（代码级已覆盖）**

模拟器无法注入多点触控：以 Task 3 单测为准，并在本计划验收记录中标注「双指滚动/捏合待真机」。

- [ ] **Step 7: 门控 E2E**

Mac 菜单栏执行「暂停输入」→ 客户端抽屉打开应显示「输入已暂停」，此时触摸不产生 Mac 事件；恢复后抽屉提示消失，点击恢复。Expected: Helper 日志只出现一次 `input disabled reason=2`，恢复时出现 `input enabled`。

- [ ] **Step 8: 释放与断线 E2E**

键盘打开并按住 Shift（或输入中）→ 抽屉里关闭键盘 → 断开连接 → 返回连接页。Expected: Helper 日志出现 `input release_all`；Mac 侧无卡住的修饰键（再次输入正常）。直接杀 App 进程后重连，同样验证。

- [ ] **Step 9: 更新 `TESTING.md` 与验收记录**

在 `harmony/TESTING.md` 增加「输入」一节：单测文件列表、E2E 命令、真实 Helper 前提、双指/长按的待验说明。在本计划末尾追加验收结论（通过项、待真机项、已知取舍：ArkUI 无橡皮擦信号、多点触控无法在模拟器注入）。

---

## Self-Review

- **Spec 覆盖**：§9 采集/归一化 → Task 6；手势直译 → Task 3；键盘（硬件 + IME）→ Task 4/7；CTRL 3/4 门控与 releaseAll → Task 2/5/8；抽屉与输入开关 → Task 8；HELLO features → Task 5。§10 抽屉项（键盘、输入开关、断开）→ Task 8；持久化无需新增键。
- **类型一致性**：`GestureEvent` 在 Task 3 定义、Task 6 使用；`ContentRect` 在 Task 6 定义并用于 `VideoSurface`/`StreamPage`；`CtrlCode` 与 `InputGate.applyCtrl` 的 code 取值一致；`InputGate` 在 Task 2 定义、Task 5 使用。
- **Review Focus 对应测试**：1 → `InputGeometry.test`（fit/clamp）；2 → Task 7 Step 7 中文输入 E2E + `ImeBridge.test`；3 → `InputGate.test`（恢复/未知 code）；4 → `InputGeometry.test`（边界 85%/40vp）；5 → Task 8 Step 8 释放与断线 E2E。
- **比例**：计划只固定签名、常量与断言，未展开完整函数体；移植算法以 Android 文件为唯一参考。

## 验收记录（2026-11-16，模拟器 MatePad Pro 13）

**通过项**

- 单测 68/68（`make test.harmony`）；主 HAP 与 ohosTest HAP 均构建安装成功。
- 右缘滑动（起点在内容区右侧 85% 内、横向位移 ≥40vp）打开抽屉，滑动过程不向服务端发送指针事件；抽屉外点关闭、输入/键盘/断开按钮工作。
- 输入采集与归一化：tap → `input_pointer kinds=1/3` 坐标 (0.500, 0.500)；drag → kind 2 连续 MOVE；longClick → 抬起时 `buttons=2`（右键）。
- CTRL 门控：真实 Helper 未授权辅助功能时收到 `input disabled reason=1`，抽屉显示「此设备未授权控制 Mac」，客户端停止发送输入；恢复授权路径由 `InputGate` 单测覆盖。
- 输入开关关闭 / 抽屉打开 / 页面退出 → `input_release_all`；关键盘 → `release_all`。
- 硬件键盘：A → `input_key keycode=29 unicode=97`；Ctrl 修饰位随 KeyEvent 上报（注入时序在多次 hdc 调用间会乱序，客户端 `ModifierTracker` 由单测覆盖）。
- IME：软键盘输入 a/b → `input_text text=a`、`text=b` 各一次（无重复、无预览泄漏）；退格 → DEL(67) down/up；中文 UTF-8 编码由 `InputProtocol` 单测覆盖。
- 断开连接 → 回到 ConnectPage，host/port 保留（192.168.10.112:7778）。

**待真机验证**

- 双指滚动与捏合（模拟器 uitest 只能注入单点）。
- 中文 IME 组合输入（`uitest uiInput inputText` 走剪贴板粘贴路径，不提交到隐藏 TextInput）。
- Mac 光标级注入全链路：已在 2026-11-16 重新授权后验证——服务端日志 `input events flowing`，模拟器单击后 Mac 光标从 (1310,594) 移到虚拟显示器内的 (3306,499)，与归一化坐标 (0.868,0.521) 一致。

**已知取舍**

- ArkUI 无橡皮擦信号，笔一律按 STYLUS 处理。
- 抽屉内开键盘先关闭抽屉再聚焦，键盘弹出延后 100ms。
- 计划 Step 7 的「中文输入 E2E」以单键事件替代（见 ledger Ruling）。

## 最终审查修复（2026-11-16）

fresh reviewer 提出 1 Critical + 5 Important，修复后单测 74/74：

- **C1（Critical）**：`ClientSession` 把 `gate.allow()`（含本地开关）当作门控回调上报，服务端 disabled→enabled 后本地开关无法恢复，输入永久失效。改为上报 `getServerEnabled()`；删除无引用的 `ClientSession.isInputEnabled()`。新增 `ClientSession.test`（fake transport：disabled → 本地关闭 → enabled，断言回调恢复 true）。
- **I1**：右缘 15% 条带的普通点击被整段吞掉。抽出 `EdgeGesture`：按下即放行，条带内移动暂扣，越过 40vp 才打开抽屉。E2E 实测右缘单击产出 `input_pointer 0.938,0.500`，滑动仍打开抽屉且不发指针。
- **I2**：应用切后台不释放按键。`StreamPage.onPageHide` 调 `releaseAll()` 并重置修饰键；E2E：按住 Ctrl 后按 Home，服务端收到 `input_release_all`。
- **I3**：原地重连换分辨率后内容矩形不重算。`VideoSurface` 缓存容器尺寸并对 `configWidth/configHeight` 加 `@Watch` 重新 fit。
- **I4**：键盘打开时修饰键 key-up 可能不转发导致 Ctrl 卡住。新增 `isModifierKey`，`KeyboardDock` 无条件转发修饰键；E2E 实测 Ctrl down/up 分别上报 `modifiers=2/0`。
- **I5（未闭合）**：中文 IME 组合输入仍无真机证据，保持「待真机验证」，不计入通过项。