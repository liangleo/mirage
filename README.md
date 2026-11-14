# Mirage

把 Android 平板/手机变成 Mac 的扩展屏或镜像屏。

当前阶段：M0–M1（镜像显示，不做输入）。设计与计划见 `docs/`（过程文档，验收后统一提交）。

## 常用命令（Makefile）

```bash
make init      # 检查工具链，初始化 Android SDK 配置
make build     # 构建 Mac 与 Android
make test      # 两端单元测试
make app       # 打包 build/Mirage.app
make run       # 打开打包好的 App
make connect   # adb 连接 Android 设备并设置 reverse
make install   # 安装 App 到 /Applications，并安装 APK 到设备
make clean     # 清理构建产物
```

`make help` 查看全部命令；`INSTALL_DIR=~/Applications make install` 可改安装位置。

## 结构

- `protocol/`：帧格式、消息定义与跨语言测试向量
- `mac/`：Swift Package（`MirageCore` 协议库 + `mirage-helper` 命令行）
- `android/`：Android App（解码与显示）
- `tools/`：联调脚本（模拟服务端/客户端）

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

- 确认只有一个 helper 在跑：`lsof -ti tcp:7777`；有多个或旧进程时先 `pkill -f mirage-helper` 再重启。
- 重新编译后必须重启 helper，旧进程仍在用旧逻辑。
- 确认 `adb reverse tcp:7777 tcp:7777` 仍在，App 里地址是 `127.0.0.1:7777`。
- 仍黑屏时看 App 日志：`adb logcat -s Mirage`，正常应出现 `first keyframe`、`configure`、`first output`。

## 菜单栏 App

```bash
bash tools/build_app.sh
open build/Mirage.app
```

菜单栏会出现显示器图标，菜单里可以：

- **副屏（虚拟显示器）** / **镜像主屏**：切换模式（会重启 helper 子进程；从副屏切回镜像时虚拟屏随旧进程退出消失）
- **分辨率**：1280×800 / 1600×1000 / 1920×1080（4K）/ 1920×1200（HiDPI 2x 编码，副屏会按该尺寸建虚拟屏；镜像模式用作编码上限），切换会重启 helper
- **帧率**：30 / 60 / 90 / 120 fps，切换会重启 helper
- **启动 / 停止**
- **打开日志**：`~/Library/Logs/Mirage/helper.log`
- **退出 Mirage**：同时结束 helper

App 启动时默认是**副屏模式并自动开始**，之后会记住你上次选择的模式和分辨率。

首次运行需要给 **Mirage.app** 授予「屏幕录制」权限，授权后重新打开。App 使用 ad-hoc 签名，每次重新打包后若权限失效，重新授权即可。

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