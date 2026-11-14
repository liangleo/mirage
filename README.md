# Mirage

把 Android 平板/手机变成 Mac 的扩展屏或镜像屏。

当前阶段：M0–M1（镜像显示，不做输入）。设计与计划见 `docs/`（过程文档，验收后统一提交）。

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
```

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