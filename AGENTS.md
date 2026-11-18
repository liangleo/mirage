# Mirage — 项目级 Agent 规范

把 Android 平板/手机变成 Mac 的扩展屏或镜像屏。当前阶段 M0–M1（镜像显示，不做输入）。

## 交流与文档

- 与用户交流默认使用中文。
- 设计/计划等过程文档**不随实施进度提交**；全部工作结束、验收通过后统一同步并一次性提交。
- 过程文档放 `docs/`，命名 `YYYY-MM-DD-<topic>.md`。

## 模块地图

每个目录有自己的 `AGENTS.md`，改动该目录前先读对应文件：

| 目录 | 内容 | 规则 |
|---|---|---|
| `android/` | Android App（Kotlin + Compose，解码与显示） | [android/AGENTS.md](android/AGENTS.md) |
| `mac/` | Swift Package（协议库 + helper + 菜单栏 App） | [mac/AGENTS.md](mac/AGENTS.md) |
| `protocol/` | 帧格式、消息定义、跨语言测试向量 | [protocol/AGENTS.md](protocol/AGENTS.md) |
| `tools/` | 联调脚本与验证工具 | [tools/AGENTS.md](tools/AGENTS.md) |
| `docs/` | 设计、计划、验收记录 | [docs/AGENTS.md](docs/AGENTS.md) |

## 跨模块硬约束

- **改协议 = 同时改** `protocol/`、两端实现、`protocol/vectors.json`，缺一不可。
- 协议细节以 `protocol/README.md` 与 `docs/2026-11-13-mirage-design.md` §5 为准；两者冲突先问用户，不要自行取舍。
- Android 端不引入 native 库（README 承诺纯 Kotlin/Java，全 ABI 可运行）。
- 两端共享的行为变更（会话配置、重连、分辨率协商）必须两端一起改并互相验证。
- 系统同一时间只允许一块 Mirage 虚拟显示器；不要绕过这个限制。

## 工具链

完整清单、前置条件与重装方式见 [docs/agent-tooling.md](docs/agent-tooling.md)。

- MCP 配置在 `.mcp.json`：`mobile-mcp`（设备控制/日志）、`android-pilot`（构建与设备验证）。
- Android UI/UX skills 在 `.claude/skills/`，触发规则见 [android/AGENTS.md](android/AGENTS.md#skills-与-mcp-触发规则已配置)。

## 构建与测试

根目录 `Makefile` 是唯一入口，不要另造脚本：

```bash
make build      # Mac + Android 构建
make test       # 两端单元测试
make connect    # adb reverse tcp:7777 tcp:7777
make install    # 安装 Mac App 并安装 APK
```

快速基线（比 make test 更快）：

```bash
cd mac && swift build
cd android && ./gradlew --quiet :app:compileDebugKotlin
```

## 启动自检（每次会话开头）

1. `pwd` 确认在仓库根。
2. `git log --oneline -10` 了解最近上下文。
3. 跑上面的快速基线；失败先修基线，再开始新任务。