# Mirage

把 Android 平板/手机变成 Mac 的扩展屏或镜像屏。

当前阶段：M0–M1（镜像显示，不做输入）。设计与计划见 `docs/`（过程文档，验收后统一提交）。

## 常用命令（Makefile）

```bash
make init      # 检查工具链，初始化 Android SDK 配置
make build     # 构建 Mac 与 Android
make test      # 两端单元测试
make app       # 打包 build/.Mirage.app（隐藏，避免 Spotlight 出现两个 App）
make run       # 打开打包好的 App
make connect   # adb 连接 Android 设备并设置 reverse
make install   # 安装 App 到 /Applications，并安装 APK 到设备
make clean     # 清理构建产物
```

`make help` 查看全部命令；`INSTALL_DIR=~/Applications make install` 可改安装位置。

## 开发工具（Skills / MCP）

Claude Code 使用的 MCP 与 Agent Skills 清单、前置条件、重装和触发规则见 [docs/agent-tooling.md](docs/agent-tooling.md)。

## 版本要求

- **macOS**：14+，仅 Apple Silicon；Xcode 27 / Swift 6。
- **USB 免调试连接（AOA）**：需要 Homebrew libusb（`brew install libusb`）；`make app` 会静态链接 libusb，运行时不需要额外 dylib。
- **Android**：**8.0（API 26）及以上**；compileSdk / targetSdk 36。App 没有 native 库，arm64 / armeabi-v7a / x86_64 设备或模拟器都可运行。
- **构建 JDK**：**17（推荐）或 21**；AGP 8.13.1 不支持 Java 25。Gradle 8.13、Kotlin 2.2.0。
- 兼容处理：`KEY_LOW_LATENCY` 仅 API 30+、`KEY_PRIORITY` 仅 API 28+，低版本自动跳过；解码器 `csd-0/csd-1` 配置失败时回退为 in-band 参数集，并按 `MediaCodecList` 选择可用的 H.264 解码器。
- Android 8/9 没有低延迟解码提示，延迟可能偏高；R 及以上可用性最好。
- 系统同一时间只允许一块 Mirage 虚拟显示器：测试或启动新 helper 前，先退出正在运行的 Mirage.app，否则 extend 会创建失败并回退镜像。

## 结构

- `protocol/`：帧格式、消息定义与跨语言测试向量
- `mac/`：Swift Package（`MirageCore` 协议库 + `mirage-helper` 命令行）
- `android/`：Android App（解码与显示）
- `tools/`：联调脚本（模拟服务端/客户端）与 AOA USB 桥接（`aoa_bridge.c`）

## Mac

```bash
cd mac
swift test
swift run mirage-helper --list-displays
swift run mirage-helper --display 1 --port 7777 --fps 60 --bitrate 20000000
swift run mirage-helper --max-width 1920 --max-height 1080
swift run mirage-helper --mode extend
swift run mirage-helper --mode extend --width 1280 --height 800
```

默认镜像主屏；`--mode extend` 创建一块虚拟显示器并推流它（在系统设置的显示器里可见）。
虚拟屏尺寸以点为单位，默认 1280×800（HiDPI 下编码 2560×1600）。
调试：`--dump-frame <png>` 保存第一帧原始画面，`--record <h264>` 保存发送的 Annex-B 码流。

### 副屏模式怎么用

1. 运行 `swift run mirage-helper --mode extend`。
2. 系统设置 → 显示器：会多出名为 Mirage 的显示器，按需要排列它的位置（通常在主屏左侧）。
3. 把窗口拖到那块屏所在的方向；Mission Control 里也能看到它。模拟器里显示的就是这块虚拟屏。
4. 新虚拟屏上没有窗口时只显示壁纸或黑色，属正常。

### 黑屏排查

- 确认只有一个 helper 在跑：`lsof -ti tcp:7777`；有多个或旧进程时先 `pkill -x mirage-helper` 再重启。
- 如果 App 显示「副屏」但手机看到的是主屏，通常是另一个 helper 已经占着 7777/虚拟屏；在菜单栏或主窗口关闭「启动/停止服务」后再打开。App 会自动识别并接管已在运行的 helper，开关会显示为开启。
- 重新编译后必须重启 helper，旧进程仍在用旧逻辑。
- 确认 `adb reverse tcp:7777 tcp:7777` 仍在，App 里地址是 `127.0.0.1:7777`。
- 仍黑屏时看 App 日志：`adb logcat -s Mirage`，正常应出现 `first keyframe`、`configure`、`first output`。

## 菜单栏 App

```bash
bash tools/build_app.sh
open build/.Mirage.app
```

开发包放在隐藏路径 `build/.Mirage.app`，避免和 `/Applications/Mirage.app` 一起出现在 Spotlight。App 是单实例的：重复启动会直接退出；helper 发现 7777 被占用时会报错退出，不会静默变成镜像。

菜单栏会出现显示器图标。App 启动后默认**只留在菜单栏**，不弹出主窗口；点菜单里的「打开主界面」打开独立操作窗口。主窗口可以：

- **启动/停止服务** 开关（停止会结束已有的 helper 进程，包括在终端里手动启动的那个）
- **启动 App 后自动启动服务** 开关：开启后，App 启动即启动 helper 并等待客户端连接（默认关闭）
- **USB 免调试连接（AOA）** 开关：通过 Android Open Accessory 直接走 USB，不需要 adb；开关会持久化，App 启动/服务启动后自动尝试连接，并在 USB 拔出/桥接退出后自动重试等待设备。手机首次连接会弹出授权，勾选「连接后一律打开 Mirage」即可自动拉起
- **登录时自动启动 Mirage** 开关：使用 `SMAppService` 注册登录项，适合配合上面的 USB 模式做插线即用
- **副屏（虚拟显示器）** / **镜像主屏**：切换模式（会重启 helper；从副屏切回镜像时虚拟屏随旧进程退出消失）
- **分辨率**：默认 **自动（匹配设备）**；也可选 960×600 / 1280×720 / 1280×800 / 1600×1000 / 1920×1080（4K）/ 1920×1200（HiDPI 2x 编码）。自动模式下 helper 收到设备 HELLO 后按设备像素重建虚拟屏，App 会自动重连一次
- **旋转**：设备旋转后 App 自动重连并上报新尺寸，helper 重建对应方向的虚拟屏
- **帧率**：30 / 60 / 90 / 120 fps，切换会重启 helper
- **日志**：主窗口下方内嵌终端风格日志，带 `HH:mm:ss` 时间戳并自动滚动；也可点「日志文件」用系统编辑器打开 `~/Library/Logs/Mirage/helper.log`
- **退出 Mirage**：同时结束 helper

菜单栏本身保留同样的模式、分辨率、帧率、启动/停止快捷入口。关闭或最小化主窗口不会退出 App，只保留菜单栏图标。

App 启动时默认是**副屏模式**，且默认不会自动启动服务；可在主界面打开「启动 App 后自动启动服务」，或直接用 `open build/.Mirage.app --args --autostart extend` 启动并自动开始推流。开发时可用 `--args --show` 强制显示主窗口，或用 `--args --usb` 启动服务并直接建立 AOA USB 连接。

### USB 免调试连接（AOA）

1. `brew install libusb`，重新执行 `make app`。
2. 在 Mac 主界面打开「USB 免调试连接（AOA）」，或 `open build/.Mirage.app --args --usb`。
3. 手机首次会弹出 USB 授权，勾选「连接后一律打开 Mirage」并确定；之后插入 USB 会自动打开 App。
4. 手机状态栏/调试浮层显示「已连接 USB」即表示走的是 accessory 通道；此时不需要 `adb reverse`。
5. 需要开机/登录后自动可用：再打开「登录时自动启动 Mirage」。USB 开关会持久化，App 启动后自动拉起 helper 并循环等待设备。登录项建议先把 App 安装到 `/Applications`（`make install-mac`）再开启。

AOA 会占用手机的 accessory 功能（adb 可能仍可用，取决于 ROM）。正常停止服务/桥接时，桥接会先发送 SIGTERM 并把 USB 设备 reset 回普通模式（实测 vivo 恢复为 `charging,adb`）；个别不支持 reset 的 ROM 才需要拔插一次。helper 因自动分辨率重启时，`mirage-aoa` 会自动重连并重放 HELLO，Android 端无需操作。

切换模式、分辨率或帧率会重启 helper，Android 端会在断开后按指数退避自动重连（首次连接失败仍需手动重试）。

首次运行需要给 **Mirage.app** 授予「屏幕录制」权限。App 默认使用本机 Apple Development 证书签名（Team ID 稳定），授权会跨启动和重新编译保留；`make run` 不会重复构建。

如果之前装过 ad-hoc 签名的版本，先在系统设置里移除旧的 Mirage 条目，或执行：

```bash
tccutil reset ScreenCapture app.mirage.menu
```

然后重新启动 App 并授权一次。没有可用证书时可 `SIGN_IDENTITY=- make app` 退回 ad-hoc 签名，但每次重新编译后需要重新授权；有多张证书时可用 `SIGN_IDENTITY=<SHA1> make app` 指定。

开发时也可以直接 `cd mac && swift run mirage-menu`（沿用终端的屏幕录制权限）。

默认捕获主显示器；超过 `--max-width/--max-height`（默认 3840×2160）的屏幕会等比缩放。
运行时每 60 帧打印一次 `stats encode_frames=… avg_encode_ms=…`。
Android 端连接后左上角显示 fps、解码耗时、码率、丢帧和估算端到端延迟。
首次捕获需要「屏幕录制」授权，授权对象是运行命令的终端 App。

验证推流（另开终端，窗口保持有画面变化）：

```bash
python3 tools/mock_client.py
```

## Android

```bash
cd android
./gradlew :app:assembleDebug
```

首次构建需要联网下载依赖。

- 首次启动弹出「连接设置」（Mac 地址 / 端口），保存后每次启动自动连接；如果检测到 Mirage USB accessory，会优先走 USB，无需填写地址。
- 连接后点屏幕右侧的窄手柄打开控制面板；未连接时在首屏点「设置」修改地址。连接断开会自动退避重连，重连期间「连接」按钮禁用，失败后才可手动重试。
- 通过 USB accessory 接入时，App 会由 `USB_ACCESSORY_ATTACHED` intent 自动拉起；首次需在系统弹窗授权。
- 连接断开后自动重连期间，首屏显示圆形进度指示（spinner）并禁用「连接」按钮。
- 设备旋转时 App 自动重连，helper 根据新的宽高重建对应方向的虚拟屏。
- 画面按视频宽高比居中；自动分辨率下与设备比例一致，通常没有黑边，手动预设比例不同时才会留黑边。
- 全屏沉浸式运行，系统状态栏/导航栏隐藏；连接后屏幕右侧有一个窄手柄，点开是滑出的控制面板（设置、调试开关、断开），面板带深色背景遮罩，不会再和顶部原生状态栏重叠。
- 调试开关打开后，左下角显示帧率、码率、丢帧、软/硬解、手机与 Mac 的分辨率，以及 `decode / e2e / rtt` 三项延迟（单位均为 ms）。
- 连接成功期间保持屏幕常亮。
- 手机重连/重启后需要重跑 `make connect` 设置 adb reverse。