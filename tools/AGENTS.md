# tools — 联调与验证脚本

开发期工具，不进入 App 产物，不作为运行时依赖。

- `mock_mac.py` / `mock_client.py`：模拟两端联调。
- `verify/`：一次性 Swift/ObjC 探针（采集、虚拟屏、编码能力验证）。
- `build_app.sh`、`make_icon.swift`、`gen_testpattern.sh`：构建与素材脚本。

约定：

- 脚本必须可重复运行，默认不修改源码或安装到系统目录。
- 一次性探针验证完即可保留，但不要再加抽象层；需要长期使用才考虑并入 `Makefile`。
- 新脚本用绝对路径或 `$(git rev-parse --show-toplevel)` 定位仓库，不依赖调用时的 cwd。
- 涉及设备/屏幕的脚本先检查前置条件（adb、权限、显示器是否存在），失败给出可操作提示。
- 不把密钥、设备序列号等本地信息写进脚本。