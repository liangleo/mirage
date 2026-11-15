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
| 0x09 | KEY（v1.1） | 客户端 → Mac |
| 0x0A | TEXT（v1.1） | 客户端 → Mac |
| 0x0B | SCROLL（v1.1） | 客户端 → Mac |
| 0x0C | UDP_CONFIG | Mac → 客户端 |

字段布局以 `vectors.json` 与两端实现为准；完整规范见 `docs/2026-11-13-mirage-design.md` §5。

## 输入消息（v1.1）

INPUT（0x04）：`u16 count` + `count × 32B`；`count` 1..32。每个采样：

```
u8 kind; u8 pointer_id; u16 buttons; f32 x, y, pressure, tilt_x, tilt_y; u64 ts_us
```

`kind`：1 down、2 move、3 up、4 cancel、5 hover。`x`/`y` 为归一化坐标（0..1，相对视频内容区，左上原点）。

KEY（0x09）18 字节：`u8 action`（1 down, 2 up）、`u8 modifiers`（bit0 Shift、bit1 Control、bit2 Option、bit3 Command、bit4 Caps Lock、bit5 Fn）、`u8 flags`（bit0 repeat、bit1 from IME）、`u8 reserved`、`u16 keycode`（Android KeyEvent）、`u32 unicode`（0 表示无）、`u64 ts_us`。

TEXT（0x0A）：`u16 byte_len`（UTF-8，1..4096）+ 文本 + `u64 ts_us`。

SCROLL（0x0B）20 字节：`u8 phase`（1 begin, 2 change, 3 end）、`u8 flags`（bit0 Command、bit1 precise）、`u16 reserved`、`f32 dx, dy`、`u64 ts_us`。

SESSION_CONFIG 末尾追加 `u8 input_caps`：bit0 指针、bit1 键盘、bit2 文本、bit3 手写笔、bit4 压感、bit5 倾斜；缺省（旧 11 字节）视为 0。

## UDP 视频数据报

TLS 控制通道建立后，视频可改走 UDP。每个数据报 16 字节头 + ≤1200 字节载荷：

```
u32 seq; u32 frame_id; u16 frag_idx; u16 frag_count;
u8 flags; u8 reserved; u16 payload_len
```

`flags`：bit0 SOF、bit1 EOF、bit2 KEY、bit3 NACK、bit4 HELLO、bit5 parity。NACK 时 `frag_idx` 为 bitmap 起始分片，`frag_count` 为 bitmap 字节数，载荷为 bitmap。FEEDBACK（0x05）为 28 字节，UDP_CONFIG（0x0C）为 40 字节。

## 测试向量

`vectors.json` 中的 `hello.hex` 是完整帧（含长度前缀）；`video.headerHex` 是 type + 18 字节头的前缀样例。两端实现必须能互相解析这些字节。