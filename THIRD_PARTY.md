# 第三方软件

[MIT License](LICENSE) 适用于 Screen Annex 自有源码。以下组件继续使用各自的许可证。

| 组件 | 来源 | 许可与交付方式 |
| --- | --- | --- |
| scrcpy 5.0.1 | [官方版本](https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1) | Apache-2.0。设备端沿用上游，macOS 和 Windows 客户端包含本项目补丁。 |
| ADB 36.0.1 与 Windows USB DLL | [android-tools-static 36.0.1](https://github.com/meator/android-tools-static/releases/tag/36.0.1) | 来自公开源码构建，按 Apache-2.0 与各依赖许可交付。声明和静态 LGPL 库的源码交付见 [ADB 对应源码](Resources/compliance/ADB-SOURCES.md)。 |
| FFmpeg、libusb、SDL、dav1d、zlib | [声明及固定版本](Resources/compliance/THIRD_PARTY_NOTICES.txt) | 按各自许可证提供。公开发行版的对应源码和重新链接材料位于同版 Release 的 `Screen-Annex-corresponding-source.zip`。许可原文和下载说明见 [Resources/compliance](Resources/compliance)。 |
| serde_json 及传递依赖 | [Cargo.lock](core/Cargo.lock) | Cargo 按锁文件获取，每个 crate 适用其自带许可证。 |
| WinUI、Windows App SDK、SDK Build Tools | [Windows 项目依赖](windows/HosMirror.Windows/HosMirror.Windows.csproj) | NuGet 或 Microsoft 官方渠道获取。 |
| LibVLCSharp / LibVLC | [LibVLCSharp.WinUI](https://www.nuget.org/packages/LibVLCSharp.WinUI/3.10.2) · [VideoLAN.LibVLC.Windows](https://www.nuget.org/packages/VideoLAN.LibVLC.Windows/3.0.21) | Windows 鸿蒙发行版随包提供 LibVLCSharp 的许可证和对应源码；首次投屏时从官方 NuGet 自动下载固定版本的原生库。见 [Windows 第三方声明](windows/compliance/NOTICE.md)。 |

HarmonyOS 的 HDC、采集与注入组件来自用户安装的 DevEco Testing，由 App 从本机自动准备。参见 [HarmonyOS 首次连接](docs/HARMONYOS.md)。

鸿蒙协议参考包含 [hnscrcpy](https://github.com/taxiao213/hnscrcpy)（Apache-2.0）。项目保留协议参考的来源链接，未随仓库复制其应用代码或 SDK 文件。
