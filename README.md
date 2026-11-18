# Screen Annex

在电脑上投屏并操控 Android 手机。每台设备有独立窗口，支持键鼠、无线调试、拖放传文件和 APK 安装。

*Mirror and control Android devices from your desktop.*

## 下载

在 [GitHub Releases](https://github.com/farceli/screen-annex/releases) 下载对应平台的软件包。ADB 和 scrcpy 已内置。

| 系统 | 下载文件 | 启动方式 |
| --- | --- | --- |
| macOS 14+ · Apple 芯片 | `Screen-Annex-macos-arm64.dmg` | 打开镜像，将 Screen Annex 拖入「应用程序」，启动后在菜单栏打开设备列表。 |
| macOS 14+ · Intel | `Screen-Annex-macos-x64.dmg` | 打开镜像，将 Screen Annex 拖入「应用程序」，启动后在菜单栏打开设备列表。 |
| Windows x64 | `Screen-Annex-windows-x64.zip` | 解压整个 ZIP，双击 `ScreenAnnex.exe`。 |

macOS 预览版使用临时签名。首次启动若被系统拦截，请确认文件来自本仓库，再在「系统设置 → 隐私与安全性」为此 App 选择「仍要打开」。 [Apple 支持说明](https://support.apple.com/102445)

## 连接手机

1. 在手机上开启开发者选项和 USB 调试，连接数据线并在手机上允许调试。Windows 如未识别调试接口，可按机型安装 [USB 驱动](https://developer.android.com/studio/run/oem-usb)。
2. 从设备列表点击「投屏」。使用无线调试时，先用手机配对弹窗中的地址和配对码配对，再用无线调试主页显示的地址连接。

当前下载版面向 Android。

## 贡献与许可

欢迎提交问题和改进。提交前请阅读 [贡献指南](CONTRIBUTING.md) 和 [安全问题报告](SECURITY.md)。

Screen Annex 自有源码采用 [MIT License](LICENSE)。第三方组件的许可和对应源码见 [第三方依赖](THIRD_PARTY.md)。
