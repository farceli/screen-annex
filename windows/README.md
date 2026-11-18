# Screen Annex for Windows

Windows 客户端使用 WinUI 3。鸿蒙由 Rust 协议内核和 LibVLC 渲染，Android 由 scrcpy 在独立窗口显示。

Windows x64 的 scrcpy 已交叉编译，完整 WinUI 构建和可移植后端回归测试已通过 GitHub Actions 验证。真机功能仍待 Windows 环境验证。

## 构建

需要 Windows x64、Visual Studio 2022 的 Windows 应用开发和 MSVC 工具、.NET 8 SDK、Rust 和 Python 3.11+。在仓库根目录执行：

```powershell
# 添加 Rust 的 Windows x64 MSVC 目标。
rustup target add x86_64-pc-windows-msvc

# 准备锁定的 scrcpy 运行文件，然后构建 WinUI 和 Rust 内核。
python scripts/vendor_scrcpy.py install --download
./windows/build.ps1

# 从完整输出目录启动应用。
& "./dist/windows-x64/ScreenAnnex.exe"
```

使用与项目依赖相符的 [Windows App Runtime 1.7](https://learn.microsoft.com/windows/apps/windows-app-sdk/downloads)。输出目录是用于本机测试的构建结果，分发前还需验证 Windows 运行环境和第三方组件的交付材料。

## 连接手机

- Android 使用单独安装的 [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools)。默认查找 `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe` 和 `PATH`。可以用 `HOSMIRROR_ADB` 指定绝对路径。
- HarmonyOS 参见 [本机组件配置](../docs/HARMONYOS.md)。默认目录为 `%LOCALAPPDATA%\Screen Annex\HarmonyOS`。
- 开启手机调试功能并确认授权后，从设备列表或任务栏通知区域发起投屏。
