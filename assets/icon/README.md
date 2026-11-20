# 图标资源

本目录只保留 App 图标源图：

```
icon/
└── mirage-1024.png   # app 图标源图
```

工具条图标已改为**矢量图**，不再放在本目录：

- Android：`android/app/src/main/res/drawable/ic_<action>_<state>.xml`（VectorDrawable）
- HarmonyOS：`harmony/entry/src/main/resources/base/media/ic_<action>_<state>.svg`

## 规格

- 6 个动作：`input` / `keyboard` / `disconnect` / `debug` / `settings` / `close`
- 4 个状态：`normal` / `hover` / `active` / `disabled`
- 24×24 viewBox，stroke 1.8，圆角线帽/线join；按各 glyph 的视觉边界归一化到约 18px
- 显示 20dp；按钮底 32dp、圆角 8dp；底色 `#99141A24`，1px 边框 `#33FFFFFF`；间距 6dp

## 颜色

| 状态 | 颜色 |
|---|---|
| normal | `#9CA3AF` |
| input / keyboard / settings active | `#38BDF8` |
| debug active | `#FBBF24` |
| disconnect active | `#F87171` |
| close hover | `#E2E8F0` |
| disabled | normal 50% 透明 |

`assets/android_harmony_toolbar_icons_v1/` 与 `assets/android_harmony_toolbar_icons_v2_calibrated/` 仅作为历史位图参考，不参与构建。