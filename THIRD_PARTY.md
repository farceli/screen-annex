# 第三方软件

[MIT License](LICENSE) 适用于 Screen Annex 自有源码。以下组件继续使用各自的许可证。

| 组件 | 来源 | 许可与交付方式 |
| --- | --- | --- |
| scrcpy 5.0.1 | [官方版本](https://github.com/Genymobile/scrcpy/releases/tag/v5.0.1) | Apache-2.0。设备端沿用上游，macOS 和 Windows 客户端包含本项目补丁。 |
| FFmpeg、libusb、SDL、dav1d、zlib | [声明及固定版本](Resources/compliance/THIRD_PARTY_NOTICES.txt) | 按各自许可证提供。配套归档、许可原文和重新链接说明位于 [Resources/compliance](Resources/compliance)。 |
| serde_json 及传递依赖 | [Cargo.lock](core/Cargo.lock) | Cargo 按锁文件获取，每个 crate 适用其自带许可证。 |
| WinUI、Windows App SDK、SDK Build Tools | [Windows 项目依赖](windows/HosMirror.Windows/HosMirror.Windows.csproj) | NuGet 或 Microsoft 官方渠道获取。 |
| LibVLCSharp / LibVLC | [LibVLCSharp.WinUI](https://www.nuget.org/packages/LibVLCSharp.WinUI/3.10.2) · [VideoLAN.LibVLC.Windows](https://www.nuget.org/packages/VideoLAN.LibVLC.Windows/3.0.21) | NuGet 包声明 LGPL-2.1-or-later。Windows 源码构建恢复这些包。发布含其 DLL 和插件的 Windows 安装包前，需复核实际分发文件的许可、声明和对应源码。 |

Android 的 ADB 与关联 DLL 由用户从 [Google 官方渠道](https://developer.android.com/tools/releases/platform-tools) 安装。HarmonyOS 的 HDC、采集与注入组件由用户分别准备。参见 [本机组件配置](docs/HARMONYOS.md)。

鸿蒙协议参考包含 [hnscrcpy](https://github.com/taxiao213/hnscrcpy)（Apache-2.0）。项目保留协议参考的来源链接，未随仓库复制其应用代码或 SDK 文件。
