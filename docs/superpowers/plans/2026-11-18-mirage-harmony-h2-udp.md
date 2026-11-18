# H2 UDP 视频实施计划

**目标**：鸿蒙客户端接入 Mac 的 UDP 视频通道（AES-256-GCM、native 收包/重组/NACK），弱网自动回退 TCP。

**状态**：已实施并真机验证（2026-11-18）；弱网丢包注入与 30 分钟长测按用户决定不做。

**依据**：设计文档 §7.4、§13 H2；Mac 端实现已存在（`mac/Sources/MirageCore/UdpProtocol.swift`、`UdpCrypto.swift`、`mac/Sources/MirageHelper/UdpVideoSender.swift`）。

## 线格式（与 Mac 端对齐）

- 数据报 = 16B 头 + 密文（明文 + 16B GCM tag）
  - 头：`seq u32 | frameID u32 | fragIndex u16 | fragCount u16 | flags u8 | reserved u8 | payloadLength u16`（大端；payloadLength = 密文长度）
  - flags：SOF=1、EOF=2、KEY=4、NACK=8、HELLO=16、PARITY=32
- 明文分片 ≤1200B；AES-256-GCM；nonce = noncePrefix(4B) + seq(u64 BE)；AAD = 16B 头
- `UDP_CONFIG`（类型 12，payload 41B）：`port u16 | cipher u8(=1 AES-256-GCM) | key 32B | noncePrefix 4B | flags u8(bit0=enabled)`
- 客户端先发 HELLO 数据报（无载荷）让服务端学习地址；服务端回 HELLO 并把后续视频转到 UDP
- 丢片：客户端发 NACK（flags=NACK，fragIndex=bitmap 起始片，fragCount=bitmap 字节数，payload=bitmap）
- 回退：客户端发 `CTRL UDP_FAILED(5)` 后服务端恢复 TCP；就绪发 `CTRL UDP_READY(6)`（服务端仅记录）

## 任务

### Task 1：ArkTS 协议层（TDD）
- `CtrlCode` 增 `UDP_FAILED=5`、`UDP_READY=6`
- `Protocol.ets`：`decodeUdpConfig(payload) -> UdpConfig`（仅接受 cipher=1，长度校验）
- 测试：正常解析、长度不足、未知 cipher 拒绝

### Task 2：ClientSession 接入
- 处理 `UDP_CONFIG` 帧：仅 Wi-Fi/TLS 且 host 非回环时启用
- 调用 native `startUdp(host, port, key, noncePrefix)`；`stop()`/重连时 `stopUdp()`
- native 事件：
  - `udpFrame`（完整帧 ArrayBuffer + key 标志 + frameID）→ 走 `listener.onVideo`（captureTs=0，e2e 不参与 p95）
  - `udpReady` → 发 `CTRL UDP_READY`，标记 `udpActive=true`，忽略 TCP VIDEO
  - `udpFailed` → 发 `CTRL UDP_FAILED`，`udpActive=false`，恢复接收 TCP VIDEO
- 单测：可注入 fake native 的适配层（如 `UdpReceiver` 接口）验证状态切换

### Task 3：native `udp_receiver.cpp`
- POSIX UDP socket + 收包线程（poll 500ms）
- HELLO 每 200ms 一次，最多 10 次；收到首个数据报即停
- AES-256-GCM（`libohcrypto`）：每次数据报独立解密，解密失败计数
- 按 frameID 重组：分片位图、SOF/EOF 判定；帧完成→回调 ArkTS（napi tsfn）
- 缺口：EOF 缺片或 5ms 未补齐 → 发 NACK（bitmap），最多 2 轮；帧号前进时丢弃残缺帧
- 失败判定：HELLO 后 1.5s 无任何数据报，或 3s 内解密失败 >20 次 → `udpFailed`
- CMake 链接 `libohcrypto`

### Task 4：Stats/UI
- UDP 模式下 e2e/p95 无时间戳来源 → 置 -1（浮层显示 `--`），fps/码率/decode 正常
- 通道标识仍显示 Wi-Fi

### Task 5：验收
- 动态画面下 UDP 流畅、p95/解码正常；丢包注入（`network link conditioner` 或 Mac 端丢片）触发 NACK 并恢复
- 关闭 UDP（模拟 udpFailed）→ 1s 内回退 TCP
- 连续运行 30 分钟不崩、无内存增长

## 风险
- HarmonyOS `CryptoArchitectureKit` GCM 的 AAD/tag 参数需按 NDK 头对接（探针已验证算法可用）
- 视频帧经 tsfn 回 ArkTS 有一次拷贝（≤200KB/帧），若 CPU 吃紧改为 native 直送解码器
- Mac 端 helper 只缓存最近 3 帧用于重传，NACK 超时窗口需匹配