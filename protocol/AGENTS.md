# 协议 — 修改规则

所有消息走同一条可靠字节流：`[u32 length][u8 type][payload]`，大端，`length = 1 + payload.length`，单帧上限 8 MiB。

## 不变量

- 未知 `type` 必须忽略，不得断开连接。
- 字段布局以 `vectors.json` 和两端实现为准；规范细节见 `docs/2026-11-13-mirage-design.md` §5。
- 新增字段只能追加到 payload 尾部，并让旧端忽略未知尾部数据；破坏性变更必须升版本并两端同步。

## 改动流程（缺一不可）

1. 更新本目录 `README.md` 的字段说明。
2. 更新 `vectors.json`，包含完整帧 hex（`hello.hex` 带长度前缀）。
3. 修改 `mac/` 和 `android/` 两端实现。
4. 两端单测都能解析新向量。

```bash
cd mac && swift test
cd android && ./gradlew :app:testDebugUnitTest
```

只改一端或只改文档的提交视为未完成。