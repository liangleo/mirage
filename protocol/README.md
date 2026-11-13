# Mirage 协议 v1

所有消息走同一条可靠字节流：

```
[u32 length][u8 type][payload]
```

- 大端；`length = 1 + payload.length`，不含自身。
- 单帧上限 8 MiB，超限视为协议错误。
- 未知 `type` 必须忽略，不得断开连接。

## 消息类型

| type | 名称 | 方向 |
|---|---|---|
| 0x01 | HELLO | 客户端 → Mac |
| 0x02 | SESSION_CONFIG | Mac → 客户端 |
| 0x03 | VIDEO | Mac → 客户端 |
| 0x04 | INPUT（v1.1） | 客户端 → Mac |
| 0x05 | FEEDBACK | 客户端 → Mac |
| 0x06 | CTRL | 双向 |
| 0x07 | PING / PONG | 双向 |
| 0x08 | BYE | 双向 |

字段布局以 `vectors.json` 与两端实现为准；完整规范见 `docs/2026-11-13-mirage-design.md` §5。

## 测试向量

`vectors.json` 中的 `hello.hex` 是完整帧（含长度前缀）；`video.headerHex` 是 type + 18 字节头的前缀样例。两端实现必须能互相解析这些字节。