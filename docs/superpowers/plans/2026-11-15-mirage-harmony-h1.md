# Mirage 鸿蒙客户端 H1（Wi-Fi 出画面）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 鸿蒙客户端通过 Wi-Fi（TCP 明文 / TLS 指纹固定）连上 Mac，完成协议握手、AVCodec 硬解与 XComponent 上屏，60fps 出画面并显示统计。

**Architecture:** 协议与状态机是纯 ArkTS（可单测），解码在 native（AVCodec surface 模式），两者通过一个窄 N-API 桥连接。状态机写成纯 reducer（`reduce(state, event) -> {state, effects}`），运行时层（`ClientSession`）负责 socket、定时器与副作用，这样连接代次、退避、超时都能脱离设备单测。

**Tech Stack:** ArkTS（HarmonyOS API 12+ / target 26）、ArkUI XComponent、`@ohos.net.socket`（TCP/TLSSocket）、`@ohos.net.mdns`、`@ohos.security.cryptoFramework`、`@ohos.data.preferences`、NDK（`native_avcodec_videodecoder`、`native_window`、`native_media_core`）、hypium 单元测试。

**Spec:** `docs/superpowers/specs/2026-11-15-mirage-harmony-client-design.md`

## Global Constraints

- 不改 Mac 端、不改协议消息；唯一允许的共享改动是往 `protocol/vectors.json` 追加测试向量。
- H1 范围只含 Wi-Fi：TCP 明文（回环）与 TLS；不含 UDP、输入、USB（H2–H4）。
- `compatibleSdkVersion = 12`、`targetSdkVersion = 26`；若工具链拒绝 12，H1 先用 26 并在 H1 验收记录中注明，H5 再评估下探。
- 只承诺前台亮屏 + 常亮；后台不保活、不声明 continuous task。
- 无遥测；设备 ID 本地随机；不得提交签名材料（`build-profile.json5` 的 `signingConfigs` 保持本机状态，提交前清空）。
- UI 文案与日志用中文；原生日志转 ArkTS 时统一前缀 `Mirage`。
- 构建固定命令（cwd 必须是 `harmony/`）：
  ```bash
  cd harmony && DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk /Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw --mode module -p product=default assembleHap --no-daemon
  ```
- 设备操作统一走 `hdc`（Wi-Fi 串号 `192.168.10.149:8710`，线缆串号 `45P0224C16000257`；以 `hdc list targets` 为准）。
- **实现期间不执行 `git commit`**；全部里程碑验收后由用户决定提交。
- 测试命令以 Task 1 产出的 `harmony/TESTING.md` 为唯一准绳；若与本文命令不一致，以 TESTING.md 为准并回填计划。

## Review Focus

1. **TLS 指纹不匹配必须在发出 HELLO 之前中止** —— 否则等于把设备 ID 与屏幕尺寸送给中间人；且在拿不到证书时拒绝连接，绝不降级为不校验（Task 5）。
2. **FrameDecoder 面对任意读取边界**：报头跨两次 read、一帧 + 下一帧开头在同一次 read、超长帧 —— 错误的重组会静默丢帧或撑爆内存（Task 2）。
3. **XComponent surface 销毁/重建**（切后台、旋转、页面重建）：解码器必须停止写入旧 window，回前台后重建并能重新出画面，不能黑屏或崩溃（Task 9）。
4. **旧连接代次的迟到回调**：断开重连后，上一个 socket 的 `onData/onClosed` 不得改写新会话状态（Task 8）。
5. **mDNS TXT 指纹与本地不一致时绝不自动连接**，只能提示"需扫码确认指纹"（Task 6 + Task 9）。

---

### Task 1: 工程骨架、测试通道与运行回路

**Files:**
- Move: `harmony/entry/src/main/cpp/*` → `harmony/probe/`（探针源码留作参考，不参与构建；H5 清理）
- Move: `harmony/entry/src/main/resources/rawfile/probe720.h264` → `harmony/probe/`
- Delete: `harmony/entry/src/main/ets/pages/Index.ets` 中的探针页，替换为 `harmony/entry/src/main/ets/pages/ConnectPage.ets`（占位）
- Modify: `harmony/entry/src/main/resources/base/profile/main_pages.json`
- Modify: `harmony/entry/build-profile.json5`（暂时移除 `externalNativeOptions`）
- Modify: `harmony/entry/oh-package.json5`（移除 `libmirage_probe.so`）
- Create: `harmony/entry/src/ohosTest/ets/test/List.test.ets`、`harmony/entry/src/ohosTest/module.json5`、`harmony/entry/src/ohosTest/ets/testability/TestAbility.ets`、`harmony/entry/src/ohosTest/ets/testrunner/OpenHarmonyTestRunner.ets`
- Create: `harmony/TESTING.md`

**Interfaces:**
- Produces: 单元测试运行回路（命令写入 `TESTING.md`）；占位页 `ConnectPage`（后续任务替换内容）；模块级 build/install/launch 命令。

- [ ] **Step 1: 建占位页并改路由**

`ConnectPage.ets`：

```ts
@Entry
@Component
struct ConnectPage {
  build() {
    Column() {
      Text('Mirage').fontSize(24).fontWeight(FontWeight.Bold)
      Text('未连接').margin({ top: 8 })
    }.width('100%').height('100%').justifyContent(FlexAlign.Center)
  }
}
```

`main_pages.json`：`{ "src": ["pages/ConnectPage"] }`

- [ ] **Step 2: 迁移探针、清掉构建引用**

把 `entry/src/main/cpp` 整体移到 `harmony/probe/`；`entry/build-profile.json5` 删除 `externalNativeOptions` 块；`oh-package.json5` 删除 `libmirage_probe.so` 依赖；删除 `entry/src/main/cpp/types` 与 `rawfile/probe720.h264`（都已在新位置）。

- [ ] **Step 3: 接入 hypium 测试模块**

`entry/oh-package.json5` 的 `devDependencies` 增加 `"@ohos/hypium": "1.0.30"`，执行：

```bash
cd harmony && /Applications/DevEco-Studio.app/Contents/tools/ohpm/bin/ohpm install
```

`ohosTest/module.json5` 按 DevEco 标准测试模块写（`name: "entry_test"`、`type: "feature"`、`deviceTypes` 与主模块一致、`dependencies` 指向 `entry`）。`OpenHarmonyTestRunner.ets` 用模板默认实现。`List.test.ets`：

```ts
import { describe, it, expect } from '@ohos/hypium';

export default function abilityTest() {
  describe('harness', () => {
    it('runs', 0, () => {
      expect(1 + 1).assertEqual(2);
    });
  });
}
```

- [ ] **Step 4: 跑通构建—安装—启动—测试四步，并写进 TESTING.md**

构建 HAP → `hdc -t <serial> install -r entry/build/default/outputs/default/entry-default-signed.hap` → `hdc shell aa start -a EntryAbility -b app.mirage.harmony`，确认界面显示"未连接"。

测试 HAP 构建与执行命令（以实际可用者为准，务必写死到 `TESTING.md`）：构建 `entry@ohosTest`，安装 `entry-ohosTest-signed.hap`，执行 `hdc shell aa test -b app.mirage.harmony -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 60000`，确认 `harness runs` PASS。

**Expected:** 四步全部成功；`TESTING.md` 含可复制的四条命令与设备串号占位说明。

- [ ] **Step 5: 记录并结束**

在 `TESTING.md` 记录：工作目录、SDK 路径、build/install/start/test 命令、日志抓取命令 `hdc shell "hilog -x | grep Mirage"`。不提交。

---

### Task 2: 协议编解码与拆帧

**Files:**
- Create: `harmony/entry/src/main/ets/core/Protocol.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/Protocol.test.ets`
- Modify: `protocol/vectors.json`（追加 `session_config`、`ping` 向量）

**Interfaces:**
- Produces:
  - `enum MessageType { HELLO=1, SESSION_CONFIG=2, VIDEO=3, INPUT=4, FEEDBACK=5, CTRL=6, PING=7, BYE=8, KEY=9, TEXT=10, SCROLL=11, UDP_CONFIG=12 }`
  - `export class FrameDecoder { append(data: Uint8Array): void; next(): Frame | null }`，`Frame = { type: number; payload: Uint8Array }`；长度 `<1` 或 `> 8MiB+1` 抛 `ProtocolError`。
  - `encodeFrame(type: number, payload: Uint8Array): Uint8Array`
  - `encodeHello(hello: Hello): Uint8Array`、`decodeSessionConfig(payload: Uint8Array): SessionConfig`、`decodeVideo(payload: Uint8Array): VideoFrame`、`encodePing(tsMicros: number): Uint8Array`、`decodePing(payload: Uint8Array): number`
  - `interface Hello { protoVersion; clientVersion; deviceID: Uint8Array; screenWidth; screenHeight; xdpi; ydpi; maxFPS; codecs; features; rotation; name }`
  - `interface SessionConfig { width; height; fps; codec; bitrate; rotation; inputCaps }`
  - `interface VideoFrame { codec; flags; frameId; captureTsMicros; annexB: Uint8Array }`
  - u64 读写用 `number`（微秒级 < 2^53），实现 `readU64/writeU64` 两个内部辅助。

- [ ] **Step 1: 先加共享向量**

在 `protocol/vectors.json` 追加下面两项（hex 已按 `android/.../net/Protocol.kt:161-173` 的布局核对：width u16、height u16、fps u8、codec u8、bitrate u32、rotation u8、inputCaps u8，payload 12 字节；PING payload 为 u64 微秒）：

```json
"session_config": {
  "hex": "0000000d020b4007803c010100902d0000",
  "fields": {"width": 2880, "height": 1920, "fps": 60, "codec": 1, "bitrate": 16814125, "rotation": 0, "inputCaps": 0}
},
"ping": {"hex": "000000090700000000000003e8", "fields": {"tsMicros": 1000}}
```

- [ ] **Step 2: 写失败的测试**

`Protocol.test.ets` 覆盖：

```ts
it('encodes hello from vectors', 0, () => {
  const bytes = encodeHello({ protoVersion: 1, clientVersion: 1,
    deviceID: new Uint8Array([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]),
    screenWidth: 2560, screenHeight: 1600, xdpi: 240, ydpi: 240,
    maxFPS: 60, codecs: 1, features: 0, rotation: 0, name: 'Mirage' });
  expect(toHex(bytes)).assertEqual(VECTOR_HELLO_HEX);
});

it('decodes session config from vectors', 0, () => {
  const f = new FrameDecoder();
  f.append(hexToBytes(VECTOR_SESSION_CONFIG_HEX));
  const frame = f.next()!;
  expect(frame.type).assertEqual(MessageType.SESSION_CONFIG);
  const cfg = decodeSessionConfig(frame.payload);
  expect(cfg.width).assertEqual(2880);
  expect(cfg.height).assertEqual(1920);
  expect(cfg.fps).assertEqual(60);
  expect(cfg.bitrate).assertEqual(16814125);
  expect(cfg.inputCaps).assertEqual(0);
});

it('assembles a frame split across reads', 0, () => {
  const full = encodePing(1000);
  const f = new FrameDecoder();
  f.append(full.slice(0, 3));
  expect(f.next()).assertNull();
  f.append(full.slice(3));
  const frame = f.next()!;
  expect(frame.type).assertEqual(MessageType.PING);
  expect(decodePing(frame.payload)).assertEqual(1000);
});

it('returns two frames from one read', 0, () => {
  const two = concat(encodePing(1), encodePing(2));
  const f = new FrameDecoder();
  f.append(two);
  expect(decodePing(f.next()!.payload)).assertEqual(1);
  expect(decodePing(f.next()!.payload)).assertEqual(2);
  expect(f.next()).assertNull();
});

it('rejects oversized and zero length', 0, () => {
  const bad = new Uint8Array([0x02,0x00,0x00,0x01, MessageType.PING]);
  expectThrows(() => { const f = new FrameDecoder(); f.append(bad); f.next(); }, 'oversized frame');
});

it('decodes video header and annex-b payload', 0, () => {
  const v = VECTOR_VIDEO; // headerHex + payloadHex from protocol/vectors.json
  const full = hexToBytes('00000017' + '03' + v.headerHex + v.payloadHex);
  const frame = new FrameDecoder();
  frame.append(full);
  const video = decodeVideo(frame.next()!.payload);
  expect(video.codec).assertEqual(1);
  expect(video.flags).assertEqual(1);
  expect(video.frameId).assertEqual(1);
  expect(video.captureTsMicros).assertEqual(1000);
  expect(toHex(video.annexB)).assertEqual('deadbeef');
});
```

- [ ] **Step 3: 运行确认失败**

Run: `harmony/TESTING.md` 中的测试命令。
Expected: FAIL，提示 `Protocol` 模块不存在 / 断言失败。

- [ ] **Step 4: 实现 `Protocol.ets`**

要点：`DataView` 大端读写；`FrameDecoder` 内部维护 `Uint8Array` 缓冲区 + 偏移，`next()` 只拷贝一次；`decodeSessionConfig` 要求 ≥11 字节、`inputCaps` 在 ≥12 时读取；`decodeVideo` 要求 ≥18 字节；`encodeHello` 要求 `deviceID.length === 16` 且 name UTF-8 ≤255 字节；未知 type 正常返回（由调用方忽略）。

- [ ] **Step 5: 运行确认通过**

Expected: 6 个测试全 PASS。

---

### Task 3: 配对解析、设置存储与设备 ID

**Files:**
- Create: `harmony/entry/src/main/ets/net/Pairing.ets`
- Create: `harmony/entry/src/main/ets/settings/SettingsStore.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/Pairing.test.ets`

**Interfaces:**
- Produces:
  - `export interface PairingPayload { host: string; port: number; fingerprintHex: string; name: string; deviceId: string }`
  - `export function parsePairingUrl(url: string): PairingPayload | null`
  - `export function decodeFingerprint(hex: string): Uint8Array | null`（必须 64 位十六进制）
  - `export function fingerprintsMatch(advertisedHex: string, savedHex: string): boolean`
  - `export interface KeyValueStore { getString(key: string): string; getInt(key: string): number; putString(key: string, value: string): void; putInt(key: string, value: number): void; flush(): Promise<void> }`
  - `export class SettingsStore { constructor(kv: KeyValueStore); load(): Settings; savePairing(host, port, fingerprintHex): Promise<void>; saveTransportMode(mode): Promise<void>; deviceId(): Uint8Array }`
  - `export interface Settings { host: string; port: number; fingerprintHex: string; transportMode: TransportMode }`
  - `export enum TransportMode { AUTO, USB, WIFI, TCP }`

- [ ] **Step 1: 写失败的测试**

```ts
it('parses a valid pairing url', 0, () => {
  const p = parsePairingUrl('mirage://pair?v=1&host=192.168.1.5&port=7778&fp=' + 'ab'.repeat(32) + '&name=Mac%20Mini&id=550e8400-e29b-41d4-a716-446655440000');
  expect(p!.host).assertEqual('192.168.1.5');
  expect(p!.port).assertEqual(7778);
  expect(p!.name).assertEqual('Mac Mini');
  expect(p!.fingerprintHex.length).assertEqual(64);
});

it('rejects bad pairing urls', 0, () => {
  expect(parsePairingUrl('https://pair?host=a&port=1')).assertNull();
  expect(parsePairingUrl('mirage://pair?v=2&host=a&port=1&fp=' + 'ab'.repeat(32) + '&id=550e8400-e29b-41d4-a716-446655440000')).assertNull();
  expect(parsePairingUrl('mirage://pair?v=1&host=a&port=0&fp=' + 'ab'.repeat(32) + '&id=550e8400-e29b-41d4-a716-446655440000')).assertNull();
  expect(parsePairingUrl('mirage://pair?v=1&host=a&port=1&fp=ab&id=550e8400-e29b-41d4-a716-446655440000')).assertNull();
  expect(parsePairingUrl('mirage://pair?v=1&host=a&port=1&fp=' + 'ab'.repeat(32) + '&id=not-a-uuid')).assertNull();
});

it('device id is 16 bytes and persisted', 0, async () => {
  const kv = new MemoryStore();
  const a = new SettingsStore(kv).deviceId();
  const b = new SettingsStore(kv).deviceId();
  expect(a.length).assertEqual(16);
  expect(toHex(a)).assertEqual(toHex(b));
});
```

（`MemoryStore` 是测试内的 `KeyValueStore` 实现。）

- [ ] **Step 2: 运行确认失败**

Expected: FAIL，模块不存在。

- [ ] **Step 3: 实现 Pairing 与 SettingsStore**

`parsePairingUrl`：严格 `mirage://pair?`（大小写不敏感）、`v === '1'`、host 非空、port 1..65535、fp 64 hex、id 为合法 UUID；解码用 `decodeURIComponent`，任何一步失败返回 null。`fingerprintsMatch` 用逐字节异或累计比较。`SettingsStore` 的 `fake` 注入见测试；生产实现随后用 `@ohos.data.preferences` 适配 `KeyValueStore`（在 Task 7 接线，Task 3 只做内存可测版 + 适配器类）。`deviceId` 不存在时生成 16 随机字节并以 hex 存回。

- [ ] **Step 4: 运行确认通过**

Expected: 3 个测试 PASS。

---

### Task 4: 传输选择器与 TCP 传输

**Files:**
- Create: `harmony/entry/src/main/ets/transport/TransportSelector.ets`
- Create: `harmony/entry/src/main/ets/transport/Transport.ets`
- Create: `harmony/entry/src/main/ets/transport/TcpTransport.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/TransportSelector.test.ets`

**Interfaces:**
- Produces:
  - `export enum TransportKind { USB, WIFI, TCP, WAIT_USB }`
  - `export interface TransportChoice { kind: TransportKind; host?: string; port?: number }`
  - `export function selectTransport(mode: TransportMode, hasAccessory: boolean, savedHost: string, savedPort: number): TransportChoice | null`
  - `export interface Transport { open(): Promise<void>; write(data: Uint8Array): Promise<void>; close(): Promise<void>; onData(cb: (data: Uint8Array) => void): void; onClosed(cb: (reason: string) => void): void }`
  - `export class TcpTransport implements Transport`（`constructor(host: string, port: number)`；`open` 5s 超时、`tcpNoDelay: true`）

- [ ] **Step 1: 写失败的测试（选择矩阵）**

```ts
it('auto prefers accessory', 0, () => expect(selectTransport(TransportMode.AUTO, true, '1.2.3.4', 7778)!.kind).assertEqual(TransportKind.USB));
it('auto falls back to wifi', 0, () => expect(selectTransport(TransportMode.AUTO, false, '1.2.3.4', 7778)!.kind).assertEqual(TransportKind.WIFI));
it('auto falls back to loopback tcp', 0, () => expect(selectTransport(TransportMode.AUTO, false, '', 0)!.kind).assertEqual(TransportKind.TCP));
it('usb waits when absent', 0, () => expect(selectTransport(TransportMode.USB, false, '1.2.3.4', 7778)!.kind).assertEqual(TransportKind.WAIT_USB));
it('wifi needs address', 0, () => expect(selectTransport(TransportMode.WIFI, false, '', 0)).assertNull());
it('tcp forces loopback', 0, () => expect(selectTransport(TransportMode.TCP, true, '1.2.3.4', 7778)!.port).assertEqual(7777));
```

- [ ] **Step 2: 运行确认失败**

Expected: FAIL，模块不存在。

- [ ] **Step 3: 实现选择器与 TCP 传输**

选择规则照 Android `TransportSelector.kt`。`TcpTransport`：`socket.constructTCPSocketInstance()`，`bind` 不需要，直接 `connect({ address: { address: host, port, family: 1 }, timeout: 5000 })`，连接后 `setExtraOptions({ tcpNoDelay: true })`，`on('message')` 把 `message` 转 `Uint8Array` 回调，`on('close')`/`on('error')` 回调 `onClosed`；`close()` 先 `off` 再 `close()`，重复调用安全。

- [ ] **Step 4: 运行确认通过**

Expected: 6 个测试 PASS。

---

### Task 5: TLS 传输与证书指纹固定

**Files:**
- Create: `harmony/entry/src/main/ets/transport/TlsTransport.ets`
- Modify: `tools/mock_mac.py`（增加 `--tls-cert` / `--tls-key`，用 `ssl` 包一层）
- Create: `harmony/entry/src/ohosTest/ets/test/Fingerprint.test.ets`

**Interfaces:**
- Produces: `export class TlsTransport implements Transport`（`constructor(host, port, fingerprintHex)`）；`export function sha256Hex(data: Uint8Array): Promise<string>`（cryptoFramework）。
- Consumes: Task 3 `decodeFingerprint`、Task 4 `Transport`。

- [ ] **Step 1: 给 mock 服务器加 TLS**

`tools/mock_mac.py` 参数：`--tls-cert cert.pem --tls-key key.pem`；存在时 `context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key); socket = context.wrap_socket(sock, server_side=True)`。同时打印 `SHA-256 fingerprint`（读取 DER 后计算）便于与客户端对照。

生成测试证书：

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout /tmp/mirage-test-key.pem -out /tmp/mirage-test-cert.pem -days 2 \
  -subj "/CN=Mirage Test"
openssl x509 -in /tmp/mirage-test-cert.pem -outform der | shasum -a 256
```

- [ ] **Step 2: 写失败的测试**

指纹工具单测：

```ts
it('sha256 matches known vector', 0, async () => {
  expect(await sha256Hex(new Uint8Array([0x61,0x62,0x63]))).assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});
```

设备级（手工，记录到 `harmony/TESTING.md` 的"H1 联调"小节）：启动 `python3 tools/mock_mac.py --file <h264> --port 7777 --tls-cert /tmp/mirage-test-cert.pem --tls-key /tmp/mirage-test-key.pem`，在设置里粘贴对应指纹 → 连接成功并收到画面；把指纹改错一位 → 连接在 UI 上显示"证书指纹不匹配"，**且 mock 服务器日志未收到任何 HELLO 字节**。

- [ ] **Step 3: 运行确认失败**

Expected: `sha256Hex` 不存在。

- [ ] **Step 4: 实现**

`connect` 用 `socket.constructTLSSocketInstance()`；`secureOptions: { protocol: [socket.Protocol.TLSv1_2, socket.Protocol.TLSv1_3], skipRemoteValidation: true }`；连接成功后 `getRemoteCertificate()` 取 `data`，`sha256Hex` 后与指纹做常量时间比较；不一致 → `close()` 并 `onClosed('证书指纹不匹配')`，**在比较通过之前不调用任何 `write`**。`open()` 在校验通过后才 resolve。证书获取抛错同样视为失败。

- [ ] **Step 5: 运行确认通过**

Expected: sha256 单测 PASS；设备级两条路径（正确指纹出画面 / 错误指纹无 HELLO 且报错）都符合预期。

---

### Task 6: mDNS 发现

**Files:**
- Create: `harmony/entry/src/main/ets/net/MdnsDiscovery.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/DiscoveryPolicy.test.ets`

**Interfaces:**
- Produces:
  - `export interface DiscoveredMac { host: string; port: number; fingerprintHex: string; name: string }`
  - `export class MdnsDiscovery { constructor(ctx: common.Context); start(onFound: (m: DiscoveredMac) => void, onError: (msg: string) => void): void; stop(): void }`
  - `export type DiscoveryDecision = 'auto' | 'needs-pairing'`
  - `export function decideDiscovery(advertisedFp: string, savedFp: string): DiscoveryDecision`

- [ ] **Step 1: 写失败的测试**

```ts
it('auto-connects only when fingerprints match', 0, () => {
  const fp = 'ab'.repeat(32);
  expect(decideDiscovery(fp, fp)).assertEqual('auto');
  expect(decideDiscovery('cd'.repeat(32), fp)).assertEqual('needs-pairing');
  expect(decideDiscovery('', fp)).assertEqual('needs-pairing');
  expect(decideDiscovery(fp, '')).assertEqual('needs-pairing');
});
```

- [ ] **Step 2: 运行确认失败** → `DiscoveryPolicy` 不存在。

- [ ] **Step 3: 实现**

`createDiscoveryService(ctx, '_mirage._tcp')`；`on('serviceFound')` 后 `resolveLocalService(ctx, info)`，取 `host.address`、`port`、TXT 里的 `fp`/`name`（按 probe 页的实现方式解码）；找到第一个有效结果后 `stop()` 并回调。`on('discoveryStart')` 的 `errorCode !== 0` 与 10s 无结果都走 `onError`（文案"未发现 Mirage（可手动输入地址或扫码）"）。

- [ ] **Step 4: 运行确认通过 + 设备验证**

单测 PASS；设备验证：Mac 上 `dns-sd -R Mirage _mirage._tcp . 7778 fp=<64hex> name=Mac`，App 内"发现 Mac"能显示并解析出 `host:7778`；把 fp 换成与本地保存不同 → 界面显示"发现「Mac」，需扫码确认指纹"而不是自动连接。

---

### Task 7: 原生桥与 AVCodec surface 解码器

**Files:**
- Create: `harmony/entry/src/main/cpp/CMakeLists.txt`
- Create: `harmony/entry/src/main/cpp/bridge.cpp`
- Create: `harmony/entry/src/main/cpp/video_decoder.h`、`video_decoder.cpp`
- Create: `harmony/entry/src/main/cpp/types/libmirage/index.d.ts`
- Modify: `harmony/entry/build-profile.json5`（恢复 `externalNativeOptions`）
- Modify: `harmony/entry/oh-package.json5`（依赖改为 `libmirage.so`）

**Interfaces:**
- Produces（ArkTS 侧导入 `libmirage.so`）：
  ```ts
  export interface NativeEvent { kind: string; frameId?: number; bytes?: number; flags?: number; captureTsMicros?: number; payload?: ArrayBuffer; reason?: string }
  export const openDecoder: (width: number, height: number, fps: number, surfaceId: string) => void;
  export const submitVideo: (data: ArrayBuffer, flags: number, frameId: number, captureTsMicros: number) => number; // 0=accepted, 1=dropped (积压)
  export const closeDecoder: () => void;
  export const setSurface: (surfaceId: string) => void;
  export const onEvent: (cb: (e: NativeEvent) => void) => void;
  ```
- 线程模型：解码在 native 自己的线程上；`submitVideo` 只入队（容量 4，满则丢弃并回调 `dropped` 事件）；`onEvent` 用 `napi_threadsafe_function` 回到 ArkTS。
- **H1 只做 surface 模式**：`OH_VideoDecoder_SetSurface` 失败或首帧 2s 超时，上报 `decoderError`，界面显示"解码器初始化失败"，不做 buffer 回退。buffer 回退（NV12 + 手动送帧）排 H2，理由是它只求可用且会改动解码线程结构；H1 的验收前提是本机 surface 路径可用（design §16 第 1 项）。

- [ ] **Step 1: 先写失败的测试（可测部分）**

解码器本身难在单测里验证；本任务的测试是**编译 + 空实现通路**：在 `ohosTest` 里断言 `openDecoder` / `submitVideo` / `closeDecoder` 可调用且不崩溃（surfaceId 传空字符串时 `submitVideo` 返回 1 并触发 `decoderError` 事件）。

```ts
it('native module is wired', 0, async () => {
  let events: NativeEvent[] = [];
  onEvent((e) => events.push(e));
  openDecoder(320, 240, 30, '');
  const rc = submitVideo(new Uint8Array([0,0,0,1,0x65]).buffer, 1, 1, 0);
  expect(rc).assertEqual(0);
  closeDecoder();
});
```

- [ ] **Step 2: 运行确认失败**（模块不存在）

- [ ] **Step 3: 实现 CMake 与 bridge**

链接：`ace_napi.z`、`native_media_vdec`、`native_media_codecbase`、`native_media_core`、`native_window`、`hilog_ndk.z`。`openDecoder` 用 `OH_NativeWindow_CreateNativeWindowFromSurfaceId(std::stoull(surfaceId), &window)`，`OH_VideoDecoder_CreateByMime("video/avc")`，`OH_VideoDecoder_RegisterCallback`，`OH_AVFormat` 设 `OH_MD_KEY_WIDTH/HEIGHT/PIXEL_FORMAT`，`OH_VideoDecoder_SetSurface(codec, window)`，`Start`。首帧前把 SPS/PPS 作为 CSD（从第一个 VIDEO 帧的 Annex-B 提取 7/8 号 NAL）填入 `OH_MD_KEY_CODEC_CONFIG`（失败则忽略，靠带内参数集）。`OnNeedInput` 从队列取帧 `memcpy` + pts + flags（关键帧 `AVCODEC_BUFFER_FLAGS_SYNC_FRAME`），队列空时先不发 EOS（流式）。`OnNewOutput` 释放 buffer 并回调 `frame` 事件（含解码耗时）。`OnError` 回调 `decoderError`。

- [ ] **Step 4: 构建并在设备上验证表面创建**

Expected: `hvigorw assembleHap` 成功；安装启动后 hilog 出现 `Mirage native: decoder created`（此时还没有视频数据，等待 Task 8/10 联调）。

---

### Task 8: 会话状态机（纯 reducer）与运行时

**Files:**
- Create: `harmony/entry/src/main/ets/core/SessionMachine.ets`
- Create: `harmony/entry/src/main/ets/core/ClientSession.ets`
- Create: `harmony/entry/src/main/ets/core/Stats.ets`
- Create: `harmony/entry/src/ohosTest/ets/test/SessionMachine.test.ets`

**Interfaces:**
- Produces:
  - `export enum SessionState { Idle, Selecting, AwaitingUsbAuth, Connecting, Streaming, Recovering, Stopped }`
  - `export type SessionEvent = { kind: 'connect' } | { kind: 'select'; choice: TransportChoice } | { kind: 'config' } | { kind: 'closed'; reason: string } | { kind: 'retry' } | { kind: 'disconnect' } | { kind: 'transportChanged' } | { kind: 'rotation' } | { kind: 'paused' }`
  - `export interface SessionModel { state: SessionState; attempts: number; reconnectAtMs: number; generation: number }`
  - `export function reduce(model: SessionModel, ev: SessionEvent, nowMs: number): { model: SessionModel; effects: SessionEffect[] }`
  - `export function backoffMs(attempt: number): number`（`min(500 * 2^(attempt-1), 5000)`）
  - `export class ClientSession`：持有 `Transport`、`FrameDecoder`、`Stats`、解码器桥；负责 PING 1s、liveness 3s、config 落地、generation 过滤、`onStateChange(cb)`。
- Consumes: Task 2 协议、Task 3 设置、Task 4/5 传输、Task 7 native 桥。

- [ ] **Step 1: 写失败的测试**

```ts
it('config moves to streaming and resets attempts', 0, () => {
  const m: SessionModel = { state: SessionState.Connecting, attempts: 3, reconnectAtMs: 0, generation: 1 };
  const r = reduce(m, { kind: 'config' }, 1000);
  expect(r.model.state).assertEqual(SessionState.Streaming);
  expect(r.model.attempts).assertEqual(0);
});

it('closed schedules retry with capped backoff', 0, () => {
  let m: SessionModel = { state: SessionState.Streaming, attempts: 0, reconnectAtMs: 0, generation: 1 };
  m = reduce(m, { kind: 'closed', reason: 'x' }, 0).model;
  expect(m.state).assertEqual(SessionState.Recovering);
  expect(m.attempts).assertEqual(1);
  expect(m.reconnectAtMs).assertEqual(500);
  expect(backoffMs(1)).assertEqual(500);
  expect(backoffMs(2)).assertEqual(1000);
  expect(backoffMs(4)).assertEqual(4000);
  expect(backoffMs(9)).assertEqual(5000);
});

it('gives up after ten attempts', 0, () => {
  let m: SessionModel = { state: SessionState.Recovering, attempts: 10, reconnectAtMs: 0, generation: 1 };
  const r = reduce(m, { kind: 'closed', reason: 'x' }, 0);
  expect(r.model.state).assertEqual(SessionState.Stopped);
});

it('manual disconnect stops retrying', 0, () => {
  let m: SessionModel = { state: SessionState.Recovering, attempts: 2, reconnectAtMs: 0, generation: 1 };
  expect(reduce(m, { kind: 'disconnect' }, 0).model.state).assertEqual(SessionState.Stopped);
});
```

- [ ] **Step 2: 运行确认失败**

- [ ] **Step 3: 实现 reducer 与运行时**

reducer 只做状态与计数（含 `retry` 时 `state=Selecting`、`transportChanged` → `Selecting` 并 `generation+1`、`paused` 保持 `Streaming`）；效果用枚举（`OpenTransport/CloseTransport/StartDecoder/RequestKeyframe/StartTimer`）。`ClientSession` 在每次建立连接时 `generation++` 并把它闭包进所有回调，回调先比对当前代次，不一致直接丢弃。liveness：任何入站帧（含 PING/VIDEO/CONFIG）刷新 `lastInboundMs`；3s 无入站 → `closed('连接无响应')`。PING：1s 一次，payload 为 `elapsedRealtimeNanos()/1000`（用 `systemDateTime.getUptime` 或 `Date.now()*1000` 的单调替代，记录所用 API）。

- [ ] **Step 4: 运行确认通过**（4 个测试 PASS）

---

### Task 9: 播放页、XComponent 上屏与统计浮层

**Files:**
- Create: `harmony/entry/src/main/ets/ui/VideoSurface.ets`
- Create: `harmony/entry/src/main/ets/ui/StatsOverlay.ets`
- Create: `harmony/entry/src/main/ets/pages/StreamPage.ets`
- Modify: `harmony/entry/src/main/resources/base/profile/main_pages.json`

**Interfaces:**
- Consumes: Task 7 `openDecoder/closeDecoder/setSurface/onEvent`、Task 8 `ClientSession`、`SessionConfig`。
- Produces: `VideoSurface({ configWidth, configHeight, onSurfaceReady: (surfaceId: string) => void, onSurfaceDestroyed: () => void })`；`StatsOverlay({ stats })`。

- [ ] **Step 1: 写界面（失败表现：页面不存在导致构建失败）**

`VideoSurface`：`XComponent({ type: 'surface', controller: this.controller })`，`onLoad` 后 `controller.getXComponentSurfaceId()` 回调 `onSurfaceReady`；`aboutToDisappear` 回调 `onSurfaceDestroyed`。尺寸按容器与 config 等比适配（`Math.min(containerW / w, containerH / h)`）。

`StreamPage`：全屏 `Stack` 包 `VideoSurface` + `StatsOverlay`，`onConfig` 后重建解码器；页面挂载时 `setSurface`，卸载时 `closeDecoder`。

`StatsOverlay`：每 500ms 从 `Stats.snapshot()` 刷新，显示 `fps · Mbps · drop` 与 `decode · e2e · rtt`、连接通道。

- [ ] **Step 2: 构建并验证黑屏之外的失败点**

Run: 构建 + 安装 + 启动。
Expected: 能进入播放页（先用假 config 渲染），hilog 打印 surfaceId；无解码器时画面为黑底，无崩溃。

- [ ] **Step 3: 修复生命周期问题**

切后台再回前台、以及横竖屏各一次，确认 `onSurfaceDestroyed → closeDecoder`、`onSurfaceReady → setSurface` 的顺序正确（日志成对出现）。旋转暂按"surface 重建即可"处理，完整 HELLO 重发在 H2。

- [ ] **Step 4: 验证通过**

Expected: 日志显示 `decoder closed` / `decoder created` 成对，页面可重复进出 5 次不崩溃。

---

### Task 10: 连接页、端到端联调与 H1 验收

**Files:**
- Rewrite: `harmony/entry/src/main/ets/pages/ConnectPage.ets`
- Modify: `harmony/entry/src/main/ets/settings/SettingsStore.ets`（接 `@ohos.data.preferences` 适配器）
- Modify: `harmony/entry/src/main/ets/entryability/EntryAbility.ets`（常亮、全屏）
- Modify: `harmony/entry/src/main/module.json5`（`ohos.permission.INTERNET`、`ohos.permission.GET_NETWORK_INFO`、`ohos.permission.KEEP_BACKGROUND_RUNNING` 不申请）
- Create: `docs/superpowers/plans/2026-11-15-mirage-harmony-h1-acceptance.md`

**Interfaces:**
- Consumes: Task 3–9 全部。

- [x] **Step 1: 实现连接页**

状态文案、连接按钮（连接中禁用 + 进度）、设置面板（Mac 地址、端口、指纹、通道选择 AUTO/USB/WIFI/TCP、发现 Mac、粘贴配对链接、扫码按钮占位）、首次无配置时自动展开设置。粘贴链接解析成功即保存并连接；发现结果按 `decideDiscovery` 决定自动连接或提示扫码。

- [x] **Step 2: 端到端（TCP 明文，开发路径）**

Mac 上：

```bash
python3 tools/mock_mac.py --file <h264 文件> --port 7777
```

App 设置 host=Mac 的 LAN IP、port=7777，连接。
Expected: 出画面；统计 fps ≈ 源帧率；hilog 有 `config 1280x800@60`、`decoder created`、周期 `frame` 日志。

- [x] **Step 3: 端到端（TLS，主路径）**

启动真实 Mac Helper（TLS 端口 7778），从 Mac UI 扫码/复制配对链接 → App 粘贴 → 连接。
Expected: 出画面；把指纹改错一位 → 拒绝连接且提示"证书指纹不匹配"。

> 大部分用例用 `tools/mock_mac.py --tls-cert/--tls-key` 替代真实 Helper（H1 不改 Mac 端），配对链接手工构造；正确/错误指纹两条路径均验证。mDNS 与真实出画面用现成 `Mirage.app` 的 `mirage-helper --wifi`（`_mirage._tcp` → `192.168.10.112:7778`）复核，`端到端 10ms` 也可计算。

- [x] **Step 4: H1 验收清单**

写入 `h1-acceptance.md` 并逐项打勾：

- [x] TLS 正确指纹出画面；错误指纹拒绝且无 HELLO 外发
- [x] 手动地址 + TCP 明文出画面
- [x] mDNS 发现：指纹一致自动连接；不一致提示扫码（真实 Helper，两条分支均 E2E）
- [x] 粘贴配对链接可用；非法链接被拒绝并提示
- [x] 60fps 稳定（统计浮层），连续 10 分钟不断流
- [x] 拔掉 Wi-Fi/关服务能进入自动重连并恢复
- [x] 切后台/回前台画面恢复，无崩溃
- [x] 旋转一次后画面恢复
- [x] 无内存持续增长（连续 10 分钟后 hilog 统计与视觉观察）

- [x] **Step 5: 回填与收尾**

把 `TESTING.md` 中的联调命令、`测试向量`、验收结果同步到计划；在 `h1-acceptance.md` 记录任何与设计的偏差（例如 compatibleSdkVersion 若被迫用 26）。不提交，等用户指示。

---

## 后续里程碑（不在本计划内）

- H2：native UDP（收包 + NDK AES-GCM + 重组/NACK）、FEEDBACK、旋转重发 HELLO、状态机补齐。
- H3：输入（触控/手势/键盘/笔）与控制抽屉。
- H4：USB AOA（native fd 传输、AUTO 降级、热插拔恢复）。
- H5：开源发布（README、LICENSE、仓库清理、构建说明）。