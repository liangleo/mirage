# Mirage 鸿蒙客户端 H4（USB AOA）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 鸿蒙客户端支持 USB AOA 传输：识别 Mirage accessory → 请求授权 → 原生 fd 读写 → 复用现有协议栈出画面；AUTO 模式优先 USB，拔出后回到等待轮询。

**Architecture:** USB 只替换传输层字节通道：原生 `usb_transport.cpp` 用 16KB 缓冲循环 `read(2)`，把原始字节块通过 threadsafe function 抛回 ArkTS；ArkTS `UsbTransport` 实现现有 `Transport` 接口，字节进入未改动的 `ClientSession`/`FrameDecoder`/`submitVideo` 链路。授权与配件选择做成可注入端口（`UsbPort`），纯逻辑可单测；`ConnectPage` 负责 AUTO 判定、授权文案与 1s 等待轮询。

**Tech Stack:** ArkTS（API 14+ / compatibleSdk 26）、`@kit.BasicServicesKit` 的 `usbManager`（`getAccessoryList` / `hasAccessoryRight` / `requestAccessoryRight` / `openAccessory` / `closeAccessory`）、NDK `read`/`write`/`poll`、napi threadsafe function、hypium 单测、hdc 真机验收。

**Spec:** `docs/superpowers/specs/2026-11-15-mirage-harmony-client-design.md` §4.2、§6（状态机）、§7.1、§7.2

## Global Constraints

- **不改 Mac 端、Android 端和协议**：USB 承载的就是现有 Mirage 帧流（`[u32 BE len][u8 type][payload]`）。
- **USB 视频字节走「原生读 → ArkTS `FrameDecoder` → `submitVideo`」**，与 TCP/TLS 同一条 ArkTS 解码路径。这是对设计 §4.2「USB 全程在 native」的有意偏离：省掉 native 侧协议/统计/心跳重复实现，代价只是每帧一次 napi 拷贝（与 TCP 路径同量级，25Mbps ≈ 3MB/s）。若真机 USB p95 > 50ms，再升级为 native 分帧直送解码器。
- **16KB 读缓冲**，`poll(fd, POLLIN, 500)` + `read(2)`/`write(2)`；**禁用 `@ohos.fileIo`**（该 fd 走 fileIo 报 EINVAL，见探针结论）。
- 配件匹配：`manufacturer === 'Mirage'` 或 `product === 'Mirage Display'`；无匹配但只有唯一配件时也采用（与 Android `findMirageAccessory` 一致）。
- ArkTS 严格模式：只用 `class`/`interface` 与显式类型；不用 `any`、不用结构化对象字面量传参、不用索引签名。
- 授权是异步系统弹窗：弹窗期间不得阻塞 UI；拒绝或超时要停回 Idle 并显示原因。
- 轮询只在**用户已点「连接」且目标为 USB** 时运行；用户点「断开」必须立即停止轮询（防止无关的自动拉起）。
- 设计 §6 的 `AwaitingUsbAuth` 状态本轮不接入 reducer：授权是 `UsbTransport.open()` 内部的一次 await，只用 `onAuthPending` 回调把状态文案改成「等待 USB 授权…」。扩展状态机要新增 AUTH 事件与测试，收益仅为文案，等真机确认需要区分状态时再加。
- 构建与单测以 `harmony/TESTING.md` 为准；H4 结束时 `make test.harmony` 必须 `Failure: 0, Error: 0`。
- **不自动执行 `git commit`**；过程文档不随进度提交，全部验收后由用户统一决定。

## Review Focus

1. **拔出 accessory 后线程与 fd 必须干净退出**：读线程卡 `read` 会挂住退出、重复 open 会叠线程/泄漏 tsfn（Task 2 + Task 3）。
2. **授权挂起/拒绝**：弹窗期间 UI 不能卡死，拒绝后不能留下半开 transport 让重连无限重试（Task 3 + Task 4）。
3. **短写**：`write(2)` 可能只写一部分，控制帧虽小也必须循环写完，否则 HELLO 撕裂后服务端报协议错误（Task 2）。
4. **解码器未就绪时的 VIDEO**：USB 字节可能比 ArkTS 处理 `SESSION_CONFIG` 更快，`submitVideo` 返回 -1 时必须丢帧不崩（现有链路已如此，Task 4 验证）。
5. **轮询不复活已停止的会话**：用户主动断开/切 Wi-Fi 后不得被 1s 轮询拉回；这一点与刚修过的 Mac 端 helper 自动拉起是同一类问题（Task 4）。

---

### Task 1: 配件选择纯逻辑

**Files:**
- Create: `harmony/entry/src/main/ets/transport/UsbDevice.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/UsbDevice.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Produces:
  - `pickAccessoryIndex(matches: boolean[]): number` —— 有匹配取**第一个**匹配下标；无匹配时若总数恰为 1 返回 0；否则 -1。

- [ ] **Step 1: 写失败测试**

```ts
import { describe, it, expect } from '@ohos/hypium';
import { pickAccessoryIndex } from '../../../main/ets/transport/UsbDevice';

export default function usbDeviceTest() {
  describe('usbDevice', () => {
    it('returns -1 when list is empty', 0, () => {
      expect(pickAccessoryIndex([])).assertEqual(-1);
    });

    it('falls back to the only accessory', 0, () => {
      expect(pickAccessoryIndex([false])).assertEqual(0);
    });

    it('rejects ambiguous lists without a match', 0, () => {
      expect(pickAccessoryIndex([false, false])).assertEqual(-1);
    });

    it('picks the first mirage accessory', 0, () => {
      expect(pickAccessoryIndex([false, true, true])).assertEqual(1);
    });
  });
}
```

并在 `List.test.ets` 注册 `usbDeviceTest()`。

- [ ] **Step 2: 运行测试确认失败**

Run: `make test.harmony`
Expected: 编译失败，`UsbDevice` 模块不存在。

- [ ] **Step 3: 实现 `UsbDevice.ets`**

```ts
export function pickAccessoryIndex(matches: boolean[]): number {
  for (let i = 0; i < matches.length; i++) {
    if (matches[i]) {
      return i;
    }
  }
  return matches.length === 1 ? 0 : -1;
}
```

- [ ] **Step 4: 运行测试并通过**

Run: `make test.harmony`
Expected: `Failure: 0, Error: 0`，新增 4 条用例通过。

---

### Task 2: 原生 USB 读写通道

**Files:**
- Create: `harmony/entry/src/main/cpp/usb_transport.h`
- Create: `harmony/entry/src/main/cpp/usb_transport.cpp`
- Modify: `harmony/entry/src/main/cpp/bridge.cpp`（`Init` 注册导出）
- Modify: `harmony/entry/src/main/cpp/CMakeLists.txt`（加入 `usb_transport.cpp`）
- Modify: `harmony/entry/src/ohosTest/ets/test/NativeBridge.test.ets`

**Interfaces:**
- Produces（`libmirage.so` 导出）：
  - `startUsb(fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void): boolean`
  - `stopUsb(): void`
  - `usbWrite(data: Uint8Array | ArrayBuffer): number`（返回写入字节数，<0 表示失败）
  - 事件 `kind`：`'data'`（`data` 为读到的字节块）或 `'closed'`（读到 EOF/错误，`data` 为 null）。

- [ ] **Step 1: 写失败测试**

在 `NativeBridge.test.ets` 现有 describe 之后追加：

```ts
it('exports usb bridge functions', 0, () => {
  expect(typeof startUsb).assertEqual('function');
  expect(typeof stopUsb).assertEqual('function');
  expect(typeof usbWrite).assertEqual('function');
});
```

（导入行同步加 `startUsb, stopUsb, usbWrite`。）

- [ ] **Step 2: 运行测试确认失败**

Run: `make test.harmony`
Expected: 编译失败或 `assertEqual('function')` 失败 —— 三个导出尚不存在。

- [ ] **Step 3: 实现原生通道**

`usb_transport.h` 声明三个 napi 入口，`bridge.cpp` 的 `desc[]` 增加：

```cpp
{"startUsb", nullptr, StartUsb, nullptr, nullptr, nullptr, napi_default, nullptr},
{"stopUsb", nullptr, StopUsb, nullptr, nullptr, nullptr, napi_default, nullptr},
{"usbWrite", nullptr, UsbWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
```

`usb_transport.cpp` 关键实现（唯一需要算法级说明的部分）：

```cpp
constexpr size_t kReadSize = 16384;
std::atomic<bool> g_running{false};
std::thread g_thread;
int g_fd = -1;
napi_threadsafe_function g_tsfn = nullptr;

// 读线程：poll 500ms 检查停止标志，read 后整块拷贝交给 JS
void ReadLoop(int fd) {
    std::vector<uint8_t> buf(kReadSize);
    while (g_running.load()) {
        struct pollfd pfd{fd, POLLIN, 0};
        int rc = poll(&pfd, 1, 500);
        if (rc < 0) {
            if (errno == EINTR) continue;
            Emit("closed", {});
            break;
        }
        if (rc == 0) continue;
        ssize_t n = read(fd, buf.data(), buf.size());
        if (n <= 0) {
            Emit("closed", {});
            break;
        }
        Emit("data", std::vector<uint8_t>(buf.begin(), buf.begin() + n));
    }
}

// 写：循环处理短写与 EINTR
int WriteAll(const uint8_t *data, size_t length) {
    size_t off = 0;
    while (off < length) {
        ssize_t n = write(g_fd, data + off, length - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        off += static_cast<size_t>(n);
    }
    return static_cast<int>(off);
}
```

- `startUsb`：已运行时先 `StopUsb()`；`napi_create_threadsafe_function` 包住 JS 回调；保存 fd；起线程。
- `stopUsb`：`g_running = false`；`g_thread.join()`（≤500ms）；`napi_release_threadsafe_function(..., napi_tsfn_release)`；清空 fd。
- 事件投递用 `napi_tsfn_nonblocking`，投递失败即丢弃（数据块可丢，控制帧会被连接层心跳判活）。
- 本任务无单测覆盖读循环本身（需要真实 accessory），以 Step 4 + Task 4 真机验收为准。

- [ ] **Step 4: 构建并跑通导出测试**

Run: `make test.harmony`
Expected: `Failure: 0, Error: 0`，导出断言通过。

---

### Task 3: `UsbTransport`（可注入端口）

**Files:**
- Create: `harmony/entry/src/main/ets/transport/UsbTransport.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/UsbTransport.test.ets`
- Modify: `harmony/entry/src/ohosTest/ets/test/List.test.ets`

**Interfaces:**
- Consumes: Task 1 `pickAccessoryIndex`；Task 2 `startUsb/stopUsb/usbWrite`。
- Produces:
  - `interface UsbPort { count(): number; isMirage(index: number): boolean; hasRight(index: number): boolean; requestRight(index: number): Promise<boolean>; open(index: number): number; close(): void }`
  - `interface UsbBridge { start(fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void): boolean; stop(): void; write(data: Uint8Array): number }`
  - `class UsbTransport implements Transport { constructor(port: UsbPort, bridge: UsbBridge, onAuthPending: () => void) }`
  - `class SystemUsbPort implements UsbPort`（生产实现，包 `usbManager`）
  - `function systemUsbBridge(): UsbBridge`（包 `libmirage.so` 三个导出）
  - `function hasUsbAccessory(port: UsbPort): boolean`

- [ ] **Step 1: 写失败测试**

用假端口/假桥，覆盖错误与成功路径：

```ts
class FakePort implements UsbPort {
  mirage: boolean[] = [];
  right: boolean = true;
  grant: boolean = true;
  opened: number = -1;
  fd: number = 7;
  count(): number { return this.mirage.length; }
  isMirage(index: number): boolean { return this.mirage[index]; }
  hasRight(index: number): boolean { return this.right; }
  requestRight(index: number): Promise<boolean> { return Promise.resolve(this.grant); }
  open(index: number): number { this.opened = index; return this.fd; }
  close(): void { this.opened = -2; }
}

class FakeBridge implements UsbBridge {
  startedFd: number = -1;
  stopped: boolean = false;
  written: number = 0;
  emit: ((kind: string, data: ArrayBuffer | null) => void) | null = null;
  start(fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void): boolean {
    this.startedFd = fd; this.emit = onEvent; return true;
  }
  stop(): void { this.stopped = true; }
  write(data: Uint8Array): number { this.written += data.length; return data.length; }
}
```

用例：
1. 无配件 → `open()` reject，消息含 `未发现 USB 设备`。
2. 无权限且拒绝授权 → reject 含 `USB 权限被拒绝`，且 `onAuthPending` 被调用一次。
3. 无权限但同意 → `start` 收到 fd；`emit('data', buf)` → `onData` 收到同内容；`emit('closed', null)` → `onClosed('USB 已断开')` 仅一次。
4. `open()` 前 `write()` → reject。
5. `close()` 后 → `bridge.stop()` 与 `port.close()` 都被调用，再 `emit('data')` 不再回调。

- [ ] **Step 2: 运行测试确认失败**

Run: `make test.harmony`
Expected: 编译失败，`UsbTransport` 不存在。

- [ ] **Step 3: 实现 `UsbTransport.ets`**

`open()` 流程：

```ts
async open(): Promise<void> {
  const matches: boolean[] = [];
  for (let i = 0; i < this.port.count(); i++) {
    matches.push(this.port.isMirage(i));
  }
  const index = pickAccessoryIndex(matches);
  if (index < 0) {
    throw new Error('未发现 USB 设备');
  }
  if (!this.port.hasRight(index)) {
    this.onAuthPending();
    const granted = await this.port.requestRight(index);
    if (!granted) {
      throw new Error('USB 权限被拒绝');
    }
  }
  const fd = this.port.open(index);
  const ok = this.bridge.start(fd, (kind: string, data: ArrayBuffer | null) => {
    if (this.closed) return;
    if (kind === 'data' && data !== null) {
      if (this.dataCb !== null) this.dataCb(new Uint8Array(data));
    } else if (kind === 'closed') {
      this.finish('USB 已断开');
    }
  });
  if (!ok) {
    this.port.close();
    throw new Error('USB 打开失败');
  }
  this.opened = true;
}
```

`write()`：未 open 时 reject；`bridge.write(data) < data.length` 视为失败并 reject `USB 写入失败`。
`close()`：`bridge.stop()` + `port.close()` + `finish`（只触发一次）。

`SystemUsbPort` 用 `usbManager.getAccessoryList()` 快照，方法按 index 访问；`open(index)` 返回 `usbManager.openAccessory(list[index]).accessoryFd`；`close()` 用保存的 handle 调 `usbManager.closeAccessory(handle)`。`systemUsbBridge()` 直接转发三个 native 导出。

- [ ] **Step 4: 运行测试并通过**

Run: `make test.harmony`
Expected: `Failure: 0, Error: 0`，5 条新增用例通过。

---

### Task 4: `ConnectPage` 接入与 USB 等待轮询

**Files:**
- Modify: `harmony/entry/src/main/ets/pages/ConnectPage.ets`

**Interfaces:**
- Consumes: Task 3 `SystemUsbPort` / `hasUsbAccessory` / `UsbTransport` / `systemUsbBridge`；现有 `selectTransport`。
- Produces: 无新公共 API。

- [ ] **Step 1: 接入真实 accessory 检测**

`connect()` 里把写死的 `false` 换成：

```ts
const port = new SystemUsbPort();
const choice = selectTransport(this.mode, hasUsbAccessory(port), host, Number.isFinite(portValue) ? portValue : 0);
```

`WAIT_USB` 分支不再返回占位文案，改为：`this.status = '等待 USB 连接…'; this.startUsbWait(); this.busy = false;`。
`USB` 分支设置 `this.usbWanted = true`、`Runtime.transportLabel = 'USB AOA'`、`Runtime.transportName = 'USB'`。
工厂分支：

```ts
if (selected.kind === TransportKind.USB) {
  return new UsbTransport(new SystemUsbPort(), systemUsbBridge(), () => {
    this.status = '等待 USB 授权…';
  });
}
```

- [ ] **Step 2: 增加等待轮询与生命周期清理**

```ts
private usbWaitTimer: number = -1;
private usbWanted: boolean = false;

private startUsbWait(): void {
  if (this.usbWaitTimer !== -1) return;
  this.usbWaitTimer = setInterval(() => {
    if (this.busy) return;
    if (!hasUsbAccessory(new SystemUsbPort())) return;
    this.stopUsbWait();
    this.connect();
  }, 1000);
}

private stopUsbWait(): void {
  if (this.usbWaitTimer !== -1) {
    clearInterval(this.usbWaitTimer);
    this.usbWaitTimer = -1;
  }
}
```

- `disconnect()`：`this.usbWanted = false; this.stopUsbWait();`
- `aboutToDisappear()`：`this.stopUsbWait();`
- `handleClosed(reason)`：在现有赋值后，若 `this.usbWanted && this.mode === TransportMode.USB`，`this.startUsbWait()` 并把状态文案改为 `USB 已断开，请重新插入`。
- 轮询只在 `usbWanted` 为用户点「连接」产生时启动；Wi-Fi/TCP 连接与「断开」都不会触发它。

- [ ] **Step 3: 构建验证**

Run: `make build.harmony`
Expected: HAP 构建成功，无 ArkTS 类型错误。

- [ ] **Step 4: 真机验收（需插线）**

准备：Mac 端 helper + AOA 桥（菜单「USB 连接（AOA）」等价）：

```bash
/Applications/Mirage.app/Contents/MacOS/mirage-helper --mode extend --port 7777 --fps 60 --auto-size --position right
/Users/leo/workspace/github/liangleo/mirage/build/aoa_bridge --port 7777
```

`make install.hap` 后逐项确认：

1. USB 模式下点「连接」→ 系统授权弹窗 → 同意 → 出画面；状态栏通道显示 USB。
2. 提前拒绝授权 → 提示「USB 权限被拒绝」，不重试轰炸。
3. 拔线 → 提示「USB 已断开，请重新插入」并进入 1s 等待；重新插线自动恢复。
4. AUTO 模式插线点连接 → 走 USB，不去连 Wi-Fi。
5. 点「断开」→ 轮询停止，插线不再自动连接；切 WIFI/TCP 连接不回归。

---

### Task 5: README 使用说明

**Files:**
- Modify: `README.md`（鸿蒙客户端小节，若无则加在 Android 客户端之后）

- [ ] **Step 1: 写入 USB 使用与已知限制**

内容要点：鸿蒙客户端 USB 为实验特性；需要 Mac 端 `mirage-aoa`（菜单「USB 连接（AOA）」或 `build/aoa_bridge --port 7777`）；首次连接弹系统授权；部分厂商 ROM 的 accessory 通道可能不通，可回退 Wi-Fi；AUTO 模式插线优先 USB；拔出后 1 秒轮询等待重插。

- [ ] **Step 2: 校对**

Run: `grep -n "鸿蒙" README.md`
Expected: 能定位新增段落，且未与 Android 的 AOA 说明重复矛盾。

---

## 验收清单（全部任务完成后执行）

- `make test.harmony` → `Failure: 0, Error: 0`（Mac/Android 测试不受影响，可顺带 `make test`）。
- Task 4 Step 4 真机五项全部通过。
- 记录真机 USB p95（`StatsOverlay` 的 e2e）；若 > 50ms，按 Global Constraints 的升级路径另立任务，不在本计划内实现。
- 过程文档不提交；是否提交实现由用户决定。