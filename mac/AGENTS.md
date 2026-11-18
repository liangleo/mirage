# macOS 端 — Swift 规范

适用范围：`mac/`。Swift 6（严格并发），macOS 14+，仅 Apple Silicon，无第三方依赖。

## 结构

| Target | 职责 |
|---|---|
| `MirageCore` | 纯逻辑：协议、编码参数、会话状态 |
| `MirageHelper` | 屏幕采集与推流 |
| `CGVirtualDisplayBridge` | ObjC 桥，创建虚拟显示器 |
| `MirageHelperCLI` | `mirage-helper` 命令行入口 |
| `MirageMenu` | 菜单栏 App |

新代码放进对应 target，不新建 target，不引入 SPM 依赖。

## 硬约束

- **并发**：跨 actor / `Task` 边界传递的类型必须 `Sendable`（协议帧已标记，别撤掉）。
- **协议**：实现以 `protocol/` 为准。字段或语义变更必须同步 `protocol/vectors.json` 和 Android 端。
- **虚拟显示器**：系统同一时间只允许一块 Mirage 虚拟屏；extend 创建失败时回退 mirror 的行为是刻意的，不要删。
- **日志**：写 `~/Library/Logs/Mirage/helper.log`，与 `make logs` 的约定保持一致。
- **UI**：菜单栏用 SwiftUI `MenuBarExtra`；保持轻量，不做常驻窗口。
- 不提交 `.build/`。

## 命令

```bash
cd mac
swift build
swift test
swift run mirage-helper --list-displays
swift run mirage-helper --mode extend --width 1280 --height 800
```

打包与安装走仓库根目录 `make app` / `make install`，不要自定义签名流程。