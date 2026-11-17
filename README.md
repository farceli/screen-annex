# Screen Annex

在电脑上投屏并操控 HarmonyOS 与 Android 设备。每台设备有独立窗口，多个投屏窗口可以并排使用。

*Mirror and control HarmonyOS and Android devices from your desktop.*

| 平台 | 当前状态 |
| --- | --- |
| macOS 14+ | SwiftUI / AppKit。已有 macOS 真机验证记录。 |
| Windows x64 | WinUI 3。已通过可移植测试和 scrcpy 交叉编译，完整 WinUI 构建及真机验收待验证。 |

## 功能

- 通过 USB 或无线调试发现设备，使用电脑的键盘和鼠标操作手机。
- 多设备投屏、窗口磁吸和置顶。可为不同设备设置名称，并从菜单栏或通知区域管理连接。
- 拖入文件发送到手机，拖入 APK 或 HAP 可请求安装。安装、覆盖和降级由手机系统决定。
- 鸿蒙窗口支持截图、H.264 视频录制、剪贴板和中文输入。Android 画面及输入由 [scrcpy](https://github.com/Genymobile/scrcpy) 处理。

## 从源码运行

### macOS

需要 macOS 14+、Swift 6 工具链、Python 3.11+ 和 curl。在仓库根目录执行：

```bash
# 从上游下载锁定的 scrcpy 运行文件并核对 SHA-256。
python3 scripts/vendor_scrcpy.py install --download

# 构建并本机签名，然后打开应用。
./scripts/build-app.sh
open "dist/Screen Annex.app"
```

`./scripts/package-dmg.sh` 可生成本地测试用 DMG。项目的公开 macOS 安装包使用 Developer ID 签名和 Apple 公证流程，入口为 [scripts/notarize.sh](scripts/notarize.sh)。

### Windows

见 [Windows 构建与运行](windows/README.md)。

### 连接 Android

1. 安装 Google 官方 [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)。Screen Annex 会查找 Android Studio 默认 SDK 路径和 `PATH`。自定义位置可通过 `HOSMIRROR_ADB` 指定 `adb` 或 `adb.exe` 的绝对路径。
2. 手机开启开发者选项和 USB 调试，连接电脑，在手机上确认调试授权。
3. 在设备列表点击「投屏」。使用无线调试时，先填写配对页面的地址和配对码，再填写无线调试主页的连接地址。配对端口和连接端口通常不同。

### 连接 HarmonyOS

需要打开开发者模式和调试功能，并按 [HarmonyOS 本机组件配置](docs/HARMONYOS.md) 准备 HDC、采集和注入组件。SDK 二进制由用户通过官方渠道取得。无线调试使用 `hdc tconn`。

## 测试和贡献

- [贡献指南](CONTRIBUTING.md)
- [架构](docs/ARCHITECTURE.md)
- [HarmonyOS 协议参考](docs/PROTOCOL.md)
- [安全问题报告](SECURITY.md)

## 许可证

Screen Annex 自有源码采用 [MIT License](LICENSE)。第三方组件和补丁适用各自的许可证。随包对应源码、补丁、版权声明及重新链接说明见 [第三方依赖](THIRD_PARTY.md)。
