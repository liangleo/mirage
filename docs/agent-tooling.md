# Agent 工具链（Skills / MCP）

长期参考文档：记录本项目使用的 MCP 与 Agent Skills、前置条件和重装方式。版本以 `skills-lock.json` 和 `.mcp.json` 为准。

## 前置条件

- Node.js 20+（MCP 通过 `npx` 启动）
- Android SDK + adb：`ANDROID_HOME` 或默认路径 `~/Library/Android/sdk`

## MCP

配置文件：项目根 `.mcp.json`（项目级作用域，可提交共享）。

| 名称 | 启动方式 | 用途 | 备注 |
|---|---|---|---|
| `mobile-mcp` | `npx -y @mobilenext/mobile-mcp@latest` | 设备点击/滑动、截图、logcat、应用安装启动 | 需要 adb 和设备/模拟器 |
| `android-pilot` | `npx -y android-pilot-mcp` | `gradle_build`、`device_screenshot`、`ui_dump`、设备管理 | 需要 `ANDROID_HOME` |

新增后需要在 Claude 里批准一次（`/mcp`），或重启会话；未批准时状态为 `Pending approval`。

重新配置：

```bash
claude mcp add mobile-mcp -s project -- npx -y @mobilenext/mobile-mcp@latest
claude mcp add android-pilot -s project -- npx -y android-pilot-mcp
```

## Skills

安装位置：

- `.claude/skills/`：Claude Code 实际加载的副本
- `.agents/skills/`：skill 源文件副本
- `skills-lock.json`：版本与来源锁

| Skill | 来源 | 用途 |
|---|---|---|
| `android-design` | [charliesbot/android-design](https://github.com/charliesbot/android-design) | 视觉设计：M3 Expressive 设计判断 |
| `mobile-android-design` | [wshobson/agents](https://github.com/wshobson/agents) | Android 设计规范、M3 与 Compose 模式 |
| `design-system-patterns` | [wshobson/agents](https://github.com/wshobson/agents) | 设计令牌、主题、组件库架构 |
| `edge-to-edge` | [android/skills](https://github.com/android/skills) | 官方：边到边适配与 inset 问题 |
| `migrate-xml-views-to-jetpack-compose` | [android/skills](https://github.com/android/skills) | 官方：XML View → Compose 迁移 |

重装（按锁文件恢复）：

```bash
npx -y skills@latest experimental_install
```

单独安装：

```bash
npx -y skills@latest add android/skills@edge-to-edge -a claude-code -y --copy
```

更新：

```bash
npx -y skills@latest update -p
```

## 触发约定

| 场景 | 工具 | 规则 |
|---|---|---|
| 构建设备端验证 | MCP `android-pilot` | `gradle_build` 成功后，用 `device_screenshot` + `ui_dump` 验证实际渲染 |
| 设备操作 / 日志 | MCP `mobile-mcp` | 需要点击、截图、logcat 时 |
| 边到边适配 | Skill `edge-to-edge` | 涉及 `Scaffold`/`TopAppBar` 变更时自动触发 |
| XML→Compose 迁移 | Skill `migrate-xml-views-to-jetpack-compose` | **仅在明确迁移任务中调用** |
| 视觉/设计判断 | Skill `android-design` | 决定界面长什么样时先加载 |
| M3 规范与 Compose 模式 | Skill `mobile-android-design` | 实现 Compose UI 时 |
| 设计令牌/主题/组件库 | Skill `design-system-patterns` | 新建或调整 token、主题、组件架构时 |

设计类 skill 不要重复叠加：视觉决策优先 `android-design`，API 细节再交给 `mobile-android-design`。

## 注意

- 这些都是开发期工具，不进入 App 产物，也不作为运行时依赖。
- `build/`、`.build/` 等内容仍按 `.gitignore` 排除。
- 修改 `.mcp.json` 或 skill 版本后，同步更新本文件。
- Figma MCP 未接入：远程与桌面 server 都需要 Figma 付费席位。需要设计规格时请用户提供截图/数值或设计文档，不要凭记忆猜测。