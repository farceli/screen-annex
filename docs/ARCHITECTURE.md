# Screen Annex 架构

桌面客户端按设备后端分别发现设备，并以平台和连接标识管理会话。每台设备有自己的窗口、连接状态和文件传输队列。

| 层 | macOS | Windows |
| --- | --- | --- |
| 桌面界面 | SwiftUI、AppKit，`SessionStore` 管理设备与会话 | WinUI 3，`MainWindow` 管理设备与会话 |
| HarmonyOS 后端 | `HosMirrorCore` 的 Swift 实现，使用系统视频框架显示 H.264 | `hosmirror_core.dll` 的 Rust 实现，通过 C ABI 向 LibVLC 提供 H.264 |
| Android 后端 | 本机 ADB 枚举、配对及文件传输，scrcpy 管理投屏和输入 | 本机 ADB 枚举、配对及文件传输，scrcpy 管理投屏和输入 |

## HarmonyOS 会话

1. 通过 HDC 确认设备在线。读取设备的 uitest 版本、屏幕尺寸和组件摘要。
2. 按版本从本机资源选择采集和控制扩展，按需通过 HDC 推送到设备。启动采集与控制守护进程。
3. 通过 `hdc fport` 分别建立视频和控制的本机转发。新设备使用设备端抽象 socket，旧设备可回退到 TCP。
4. 视频通过 h2c、gRPC 和 protobuf 携带 Annex B H.264。控制通过 uitest JSON-RPC 和 HDC shell 执行。
5. 退出或启动失败时释放本次会话创建的转发和设备端进程。

协议字段和组件选择见 [协议参考](PROTOCOL.md)。设备端组件的本机配置见 [HarmonyOS 本机组件配置](HARMONYOS.md)。

## Android 会话

宿主把设备选择、标题、画质和置顶偏好传给相应架构的 scrcpy 客户端。客户端与设备端 server 固定在同一版本。桌面补丁为宿主提供窗口磁吸和拖放桥接，Windows 补丁还会报告首帧。

运行归档由 [vendor_scrcpy.py](../scripts/vendor_scrcpy.py) 下载并核对 SHA-256。固定版本、补丁和重新链接步骤见 [第三方软件](../THIRD_PARTY.md)。
