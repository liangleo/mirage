# Mirage v1.0.0

Mirage 把 Android / HarmonyOS 平板或手机变成 Mac 的扩展屏或镜像屏。

## 客户端

- Wi-Fi（TLS + 证书指纹固定）与 USB AOA 两条通道，AUTO 自动降级并在插线时回切 USB
- UDP 视频：AES-256-GCM、分片重组、NACK 重传、按帧号顺序交付、弱网回退 TCP
- 触控 / 鼠标 / 键盘 / 手写笔输入，服务端门控，断开自动释放按键
- 断线保留播放页并自动重连（5 分钟窗口），旋转自动重建虚拟屏并恢复
- 本轮 Android 客户端重构：会话状态机、单页连接页、右下角设置工具条、统计浮层、Toasts
- 工具条图标统一为矢量图（Android VectorDrawable / HarmonyOS SVG）

## Mac Helper

- 连接 `ready` 后重新请求关键帧；强制帧回退最后一帧完整画面，首次出画面 <1s
- AOA 桥缓存最新 HELLO，USB 下旋转生效；回环 AOA 连接允许输入
- 快速重启时虚拟屏创建失败会重试 3 次再回退镜像

## 已知限制

- 只在实测机型（Android vivo PD2309、HarmonyOS WEB-W00）上验收
- 未做长时间 soak 与弱网吞吐压测
- HarmonyOS 固定 TLS 1.2
