# 鸿蒙客户端构建与测试

所有命令在仓库根目录执行。设备串号见 `hdc list targets`（模拟器 `127.0.0.1:5555`，真机 Wi-Fi 串号 `192.168.10.149:8710`）。

## 常量

```bash
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export HVIGOR=/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw
export HDC=/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc
export DEV=<设备串号>
```

## 模拟器（无平板时）

```bash
/Applications/DevEco-Studio.app/Contents/tools/emulator/Emulator -start "MatePad Pro 13" -noWindow
```

首次需 `Emulator -license accept` 与 `Emulator -install -deviceType tablet -osVersion "HarmonyOS 7.0.0(26.0.0)"`（镜像约 1.5G）。启动后 `hdc list targets` 出现 `127.0.0.1:5555`。

## 构建

```bash
cd harmony && "$HVIGOR" --mode module -p product=default assembleHap --no-daemon
```

```bash
cd harmony && "$HVIGOR" --mode module -p product=default -p module=entry@ohosTest assembleHap --no-daemon
```

产物：
- `harmony/entry/build/default/outputs/default/entry-default-signed.hap`
- `harmony/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap`

## 安装与启动

```bash
"$HDC" -t "$DEV" install -r harmony/entry/build/default/outputs/default/entry-default-signed.hap
```

```bash
"$HDC" -t "$DEV" install -r harmony/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap
```

```bash
"$HDC" -t "$DEV" shell aa start -a EntryAbility -b app.mirage.harmony
```

## 单元测试（hypium）

```bash
"$HDC" -t "$DEV" shell aa test -b app.mirage.harmony -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 60000
```

通过标志：`OHOS_REPORT_RESULT: stream=Tests run: N, Failure: 0, Error: 0`。

## 日志与截图

```bash
"$HDC" -t "$DEV" shell "hilog -x | grep -i mirage"
```

```bash
"$HDC" -t "$DEV" shell "snapshot_display -f /data/local/tmp/shot.jpeg" && "$HDC" -t "$DEV" file recv /data/local/tmp/shot.jpeg /tmp/shot.jpeg
```

## H1 联调

Mock 服务器（TCP 明文）：

```bash
python3 tools/mock_mac.py --file <h264> --port 7777
```

Mock 服务器（TLS，指纹固定用）：

```bash
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout /tmp/mirage-test-key.pem -out /tmp/mirage-test-cert.pem -days 2 -subj "/CN=Mirage Test"
python3 tools/mock_mac.py --file <h264> --port 7777 --tls-cert /tmp/mirage-test-cert.pem --tls-key /tmp/mirage-test-key.pem
```

指纹：`openssl x509 -in /tmp/mirage-test-cert.pem -outform der | shasum -a 256`；mock 启动首行也会打印 `tls fingerprint=…`。

Mock 支持 `--host/--port/--fps/--width/--height/--file`（TLS 端口建议 7791，避开真实 Helper 的 7777）。

配对链接（`parsePairingUrl` 严格校验，`id` 必须是 UUID）：

```
mirage://pair?v=1&host=127.0.0.1&port=7791&fp=<64 位 hex>&id=11111111-2222-3333-4444-555555555555&name=MockMac
```

指纹改错一位即可验证"拒绝且无 HELLO 外发"：服务端只会出现 `tls handshake ok / client connected`，不会出现 `hello received`。

## UI 自动化（uitest）

```bash
"$HDC" -t "$DEV" shell "uitest uiInput click 1308 1199"
"$HDC" -t "$DEV" shell "uitest uiInput inputText 1400 983 '$URL'"
"$HDC" -t "$DEV" shell "uitest uiInput keyEvent Back"
"$HDC" -t "$DEV" shell "uitest dumpLayout -p /data/local/tmp/layout.json" && "$HDC" -t "$DEV" file recv /data/local/tmp/layout.json /tmp/layout.json
```

坐标按模拟器原生 2880×1920（截图缩放到 2000 宽时乘 1.44）。**输入文本后软键盘会遮住底部"连接/断开"，先 `keyEvent Back` 收起键盘再点。**

通道按钮会重置端口：`Wi-Fi` → 7778（TLS），`TCP` → 7777（本机回环），`AUTO` → 留空（按已保存配置选择）。

真实 Helper 联调：`/Applications/Mirage.app/Contents/MacOS/mirage-helper --mode extend --port 7777 --fps 60 --wifi --auto-size --position right`；广播 `_mirage._tcp` → `Mirage`，TXT `fp=<64hex>`。发现功能依赖 Helper 在运行（`dns-sd -B _mirage._tcp local` 能查到记录）。

验收记录：[docs/superpowers/plans/2026-11-15-mirage-harmony-h1-acceptance.md](../docs/superpowers/plans/2026-11-15-mirage-harmony-h1-acceptance.md)。

mDNS 测试广播（Mac）：`dns-sd -R Mirage _mirage._tcp . 7778 fp=<64hex> name=Mac`。

## 输入（H3）

单测文件：`InputProtocol.test`（INPUT/KEY/TEXT/SCROLL/CTRL 编解码）、`InputGate.test`（CTRL 3/4 门控、release_all）、`GestureMapper.test`（单击/长按/拖动/双指滚动/捏合/笔/取消）、`KeyMapping.test`（键码、unicode、修饰键）、`InputGeometry.test`（内容区等比、归一化、右缘判定）、`ImeBridge.test`（提交文本/删除命令）。

前提：真实 Helper 需要「屏幕录制」（extend 模式创建虚拟显示器）和「辅助功能」（注入输入）两项授权。重签名后系统设置里可能仍显示已勾选但实际失效（表现为 `SCStreamErrorDomain -3801` 或 `input disabled reason=1`），此时删除该条目并用 `+`（⌘⇧G）重新添加 `/Applications/Mirage.app/Contents/MacOS/mirage-helper`。用 `mirage-helper --input-selftest` 确认 `input_accessibility=1`；授权生效约 1 秒后日志出现 `input enabled`。

E2E（模拟器原生 2880×1920，视频铺满时）：

```bash
"$HDC" -t "$DEV" shell "uitest uiInput click 1440 960"          # 单击
"$HDC" -t "$DEV" shell "uitest uiInput drag 1200 900 1700 900"  # 拖动
"$HDC" -t "$DEV" shell "uitest uiInput longClick 1440 960"      # 长按 → 右键（buttons=2）
"$HDC" -t "$DEV" shell "uitest uiInput drag 2820 960 2300 960"  # 右缘滑动 → 打开抽屉
"$HDC" -t "$DEV" shell "uitest uiInput click 2700 960"          # 右缘条带内单击 → 仍应发送 input_pointer
"$HDC" -t "$DEV" shell "uitest uiInput keyEvent 2017"           # 硬件键 A
"$HDC" -t "$DEV" shell "uitest uiInput keyEvent 2055"           # 退格 → DEL down/up
```

客户端侧协议校验（无需辅助功能）：在 Mac 上运行 `mirage-helper --serve-selftest --tls --seconds 300`，客户端手动连接 Wi-Fi 7778；日志出现 `input_pointer kinds=1/2/3`、`input_key`、`input_text`、`input_release_all` 即表示采集与映射正确。抽屉里打开键盘后，软键盘按键走 IME 文本路径（`input_text text=a` 等，每次只发一次）；关闭键盘后硬件键走 KEY 路径（含 unicode）。

待真机验证：双指滚动/捏合（模拟器只能注入单点）、中文 IME 组合输入（`uitest uiInput inputText` 的粘贴路径不会提交到隐藏 TextInput，仅单测覆盖 UTF-8）、橡皮擦（ArkUI 无橡皮擦信号，按笔处理）。