# 图标资源

右上角工具条与 app 图标共用的位图资源，全部为透明底 PNG（96×96）。

```
icon/
├── mirage-1024.png          # app 图标源图
├── source/contact_sheet.png # 切图总表（第三排为工具条按钮）
├── input/                   # 触控开关：normal/hover/active/disabled
├── keyboard/                # 键盘：normal/hover/active/disabled
├── disconnect/              # 断开：normal/hover/danger/disabled
├── debug/                   # 调试：normal/disabled
├── gear/                    # 收起态齿轮：normal/disabled
└── close/                   # 展开态收回 X：normal
```

- 前三个目录由 `tools/extract_icons.py` 从 `source/contact_sheet.png` 第三排切出：
  按 alpha 连通域定位、剔除文字标签，四态共用同一缩放比例并按笔画核心居中，
  统一到 52/96 的核心尺寸。
- `debug` / `gear` / `close` 由 `tools/gen_extra_icons.py` 自绘。
- 修改后需要把结果同步到 `harmony/entry/src/main/resources/base/media/ic_<action>_<state>.png`。

```bash
pip install pillow
python3 tools/extract_icons.py assets/icon/source/contact_sheet.png assets/icon
python3 tools/gen_extra_icons.py assets/icon
```
