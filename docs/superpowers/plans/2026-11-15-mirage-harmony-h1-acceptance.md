# Mirage 鸿蒙客户端 H1 验收记录

日期：2026-11-15
计划：[2026-11-15-mirage-harmony-h1.md](2026-11-15-mirage-harmony-h1.md)（Task 10 Step 4）

## 环境

| 项 | 值 |
|----|----|
| 设备 | HarmonyOS 模拟器 "MatePad Pro 13"（2880×1920，arm64-v8a） |
| 系统 | HarmonyOS 7.0.0.107（API 26） |
| 串号 | `hdc -t 127.0.0.1:5555` |
| 构建 | DevEco 内置 SDK，`JAVA_HOME=…/jbr`，`DEVECO_SDK_HOME=…/sdk` |
| 服务端 | `tools/mock_mac.py`（`harmony/probe/probe720.h264`，H.264） |
| 方式 | 全程未连接真实平板；UI 由 `uitest uiInput` 驱动，截图 `snapshot_display` |

`compatibleSdkVersion` 按 H1 约束暂定 26（工具链未拒绝 12，但 H1 以 26 验收；H5 再评估下探）。

## 结果

| 验收项 | 结果 | 证据 |
|--------|------|------|
| 单测（harness/protocol/pairing/selector/fingerprint/discovery/sessionMachine/nativeBridge） | ✅ 35/35 | `OHOS_REPORT_RESULT: stream=Tests run: 35, Failure: 0, Error: 0` |
| TLS 正确指纹出画面 | ✅ | mock TLS 7791，`tls handshake ok → hello received → config sent`；截图全屏 1280×720，`30 fps · 0.7 Mbps · drop 0`，`RTT 9–11ms`，解码 `HW` |
| 错误指纹拒绝且无 HELLO 外发 | ✅ | 改一位指纹后：状态立即 `证书指纹不匹配`；服务端只见 `tls handshake ok / client connected`，从未出现 `hello received`；且不再退避重试 |
| 手动地址 + TCP 明文出画面 | ✅ | mock TCP 7790，`29 fps · 0.5 Mbps · drop 0`，`RTT 11ms` |
| 粘贴配对链接可用 | ✅ | `mirage://pair?v=1&host=…&port=…&fp=…&id=<uuid>&name=…` → `已导入 MockMac`，随后成功连接 |
| 非法配对链接被拒绝 | ✅ | 缺 `id` 的链接提示 `配对链接无效`（`parsePairingUrl` 要求 UUID） |
| 断线进入自动重连并恢复 | ✅ | 停 server：`Recovering`，退避 0.5/1/2/4s 连续 gen2→gen5；重启 server 后约 2s 自动连上，恢复收帧与画面 |
| 切后台/回前台画面恢复，无崩溃 | ✅ | 5 次进出播放页，`decoder opened/closed` 与 `surface ready/destroyed` 成对；前后台切换画面持续 |
| mDNS 发现（指纹不一致提示扫码） | ✅ | 点"发现 Mac"找到真实 Helper `leo的MacBook Pro`（`_mirage._tcp`），TXT 指纹与本地保存不一致 → 提示`需扫码确认指纹`，未自动连接；主机/端口自动填为 `192.168.10.112:7778` |
| mDNS 自动连接分支（指纹一致） | ✅ | 保存真实 Helper 指纹后再点"发现 Mac" → 提示`自动连接…`，直接进入播放页出画面，Helper 日志第二次 `client connected` |
| 真实 Helper Wi-Fi 出画面（非 mock） | ✅ | `mirage-helper --wifi` 广播 `_mirage._tcp`，模拟器直连 `192.168.10.112:7778` TLS 成功；macOS 桌面实时显示，`解码 20.5ms · 端到端 10ms · RTT 1ms · HW`，drop 0 |
| 旋转一次后画面恢复 | ✅ | `Emulator -instance "MatePad Pro 13" -rotation left/right`；转屏后页面重建 → 新 `surface ready` + `decoder opened`，画面与统计自动恢复（29fps，drop 0） |
| 端到端时延（e2e） | ✅ 真实服务端 / mock 显示 `--` | 真实 Helper 下发 16 字节 PING，显示 `端到端 10ms`；mock 只发 8 字节 PING（与 Android `Messages.encodePing` 一致），拿不到 Mac 时钟故显示 `--`，非客户端缺陷 |
| 60fps 稳定 + 10 分钟不断流 | ✅ | mock `--fps 60`（1280×720）：10 分钟后浮层 `60 fps · 1.2 Mbps · drop 0`，`RTT 7–15ms`；mock 与会话日志无断开 |

## 浸泡（60fps，10 分钟 + 5 分钟观察）

- 起始 RSS：`213560 kB`（刚从 30fps 切到 60fps）
- 10 分钟后：`263004 kB`，浮层 `60 fps · 1.2 Mbps · drop 0`，`解码 201.2ms · RTT 15ms · HW`
- 继续 5 分钟（19:08–19:12）：`231692 / 282328 / 259736 / 237256 / 269836 kB` —— 在 230–280MB 区间波动，无上升趋势
- 期间 `hilog` 无 `decoderError`、无断流；结论：无内存持续增长（模拟器图形内存波动属正常）

## 联调中发现并修复的问题

1. **TLS `message` 监听时机**：必须在 `connect()` 成功之后注册；提前注册收不到任何入站数据（HarmonyOS 7.0 实测）。
2. **socket 未 bind**：`constructTLSSocketInstance()` 后 `connect` 前需 `bind({address:'0.0.0.0',port:0,family:1})`，否则报 "No bind socket"。
3. **surface 模式缓冲处理**：`OH_VideoDecoder_FreeOutputBuffer` 只释放不渲染，必须用 `RenderOutputBuffer`（否则黑屏但解码事件正常）。
4. **重连退避链断裂**：`RETRY` 后曾停在 `Selecting`，打开失败触发的 `CLOSED` 被状态机忽略，重试只到第 2 次；改为 `RETRY → Connecting` 后按 0.5/1/2/4/5s 退避到 10 次上限。
5. **指纹不匹配不应重试**：永久错误，现在首次失败即 `Stopped` 并在 UI 提示，不再空转退避。

## 已知取舍

- 模拟器上 mock 的 `decodeMs` 约 200–500ms，真实 Helper（2880×1920）反而只有 ~20ms；与片源/关键帧间隔有关，不影响 H1 出画面结论。
- "发现 Mac"要求 Mac 侧 Helper **正在运行并广播** `_mirage._tcp`；此前误判为模拟器本地网络权限问题的现象，实因 Helper 未启动（`dns-sd -B _mirage._tcp` 无任何记录）。
- 调试日志已清理：移除 TLS 逐包 `recv/send` 与解码器每 30 帧 `output` 打印；保留会话 `closed`/`open failed`（低频、排障需要）。
- UI 自动化注意：软键盘会遮住底部"连接/断开"，脚本需先 `keyEvent Back` 收起键盘（非应用缺陷）。
- 模拟器重启后 `hdc rport` 全部失效，且设备侧可能残留旧端口的转发监听（表现为 App 卡"连接中"、服务端收不到连接）；换端口重新 `hdc rport` 即可。
- 模拟器重启（非冷启动）保留已安装的 App 与 preferences（host/port/指纹不用重填）。