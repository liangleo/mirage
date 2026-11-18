# Android 端 — Compose UI 规范

适用范围：`android/`。技术栈 Kotlin 2.2.0 + AGP 8.13.1 + Gradle 8.13，Compose BOM 2025.06.00，minSdk 26 / targetSdk 36，构建 JDK 17/21。

## UI 硬约束

- **Jetpack Compose ONLY**。禁止 XML 布局、`findViewById`、Material 2 组件。
- **版本以 `app/build.gradle.kts` 为准**。仓库目前没有 `libs.versions.toml`，不要凭空引用或新建。
- **设计令牌**：新代码的间距、颜色、字体一律从 `MaterialTheme` 获取；禁止新增硬编码 `dp` 或 `Color(0xFF...)`。需要项目级 token 时在 `ui/Theme.kt` 定义后引用。
  - 存量例外：`MainActivity.kt`、`ui/VideoView.kt` 已有硬编码尺寸。改动这些文件时就近收敛，不做无关重构。
- **图标**：用 `material-icons-core` 的 `Icons.Outlined` 或已有 `ImageVector`；不引入新图标库。
- **动效**：用 `MaterialTheme.motionScheme`（`defaultSpatialSpec`、`fastEffectsSpec` 等）；不自定义 `tween`/`spring` 参数。
- **列表**：带操作入口的列表项用 `ListItem`（或可用的 M3 Expressive 变体），不手写 `Row` + `Modifier.clickable`。
- **自适应**：Compact (<600dp) `NavigationBar`；Medium (600–840dp) `NavigationRail`；Expanded (>840dp) `NavigationRail` + 双栏。当前是单屏镜像界面，没有多页导航时不要硬加。
- **边到边**：`Scaffold` 必须处理 `WindowInsets`；`enableEdgeToEdge()` 下用 `windowInsetsPadding` 避让状态栏，不用固定高度的手动 padding。
- **无障碍（不可协商）**：`IconButton` 必须有 `contentDescription`（纯装饰用 `null` 且父容器语义完整）；自定义可点击 Composable 加 `Modifier.minimumInteractiveComponentSize()`。

## Skills 与 MCP 触发规则（已配置）

| 场景 | 工具 | 触发规则 |
|---|---|---|
| 构建设备端验证 | MCP `android-pilot` | `gradle_build` 成功后，用 `device_screenshot` + `ui_dump` 验证实际渲染 |
| 设备点击/截图/logcat | MCP `mobile-mcp` | 需要操作设备或读日志时 |
| 边到边适配 | Skill `edge-to-edge` | 涉及 `Scaffold`/`TopAppBar` 变更时自动触发 |
| XML→Compose 迁移 | Skill `migrate-xml-views-to-jetpack-compose` | **仅在明确迁移任务中调用** |
| 视觉/设计判断 | Skill `android-design` | 决定界面长什么样时先加载，再加载 API 类 skill |
| M3 规范与 Compose 模式 | Skill `mobile-android-design` | 实现 Compose UI 时 |
| 设计令牌/主题/组件架构 | Skill `design-system-patterns` | 新建或调整 token、主题、组件库时 |

Skills 已安装到 `.claude/skills/`（源文件 `.agents/skills/`，版本锁 `skills-lock.json`）。不要在任务中重复加载互相冲突的设计 skill：视觉决策优先 `android-design`。Figma MCP 未启用（远程与桌面 server 都需 Figma 付费席位），需要设计规格时向用户索取截图/数值，不要凭记忆猜测。完整清单、前置条件与重装方式见 [../docs/agent-tooling.md](../docs/agent-tooling.md)。

## 当前结构

- `app/src/main/java/app/mirage/MainActivity.kt`：主界面（连接、悬浮工具栏、调试面板）
- `ui/VideoView.kt`：SurfaceView 显示
- `net/`：协议编解码与客户端（`MirageClient`、`Protocol`、`Liveness`、`StreamStats`）
- `video/`：MediaCodec 解码（`VideoDecoder`、`DecodeQueue`、`AnnexB`）

不要为了“整洁”搬动这些文件；结构调整单独提出来做。

## 平台兼容（不要回退）

- `KEY_LOW_LATENCY` 仅 API 30+、`KEY_PRIORITY` 仅 API 28+，低版本跳过。
- 解码器 `csd-0`/`csd-1` 配置失败时回退 in-band 参数集，并按 `MediaCodecList` 选择可用 H.264 解码器。
- 不引入 native 库，保持全 ABI 可运行。

## 命令

```bash
./gradlew --quiet :app:compileDebugKotlin   # 快速编译
./gradlew :app:lintDebug                    # lint，必须无 fatal
./gradlew :app:testDebugUnitTest            # 单元测试
```

验证 UI 时优先装到真机/模拟器实际操作；无法运行时明确说明，不要只凭编译通过就宣称完成。