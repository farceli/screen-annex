# ADB 对应源码和重新链接

Screen Annex 随包分发的是从 AOSP 源码构建的 `android-tools-static` 36.0.1。macOS 使用 universal2 `adb`，Windows x64 使用 `adb.exe` 和同一发行版的 `AdbWinApi.dll`、`AdbWinUsbApi.dll`。原始版本、归档和文件的 SHA-256 记录在 `scrcpy.lock.json`。ADB 和 scrcpy 是独立程序。

公开 macOS DMG 和 Windows 发行目录的 `Source Code` 包含上游 `android-tools-static-36.0.1-src-windows.zip` 与 `packagecache/`。这个源码 ZIP 适用于两平台，比上游通用源码包多包含 Windows USB DLL 的源码；`packagecache/` 提供发行构建选用的 Meson Wrap 源码和补丁。它们连同源包中的 Meson 配方用于重新链接静态库（包括 libusb 1.0.29）。许可和归属原文在 `licenses/ADB-NOTICES.txt` 以及各源码归档中。Windows 的 GCC 16.1.0 运行库适用 GCC Runtime Library Exception。

1. 解开源码 ZIP，将 `packagecache/` 复制到解包后的 `subprojects/packagecache/`。可以先修改 libusb 的对应源码，或按 Meson Wrap 的规则提供本地修改后的库。原始校验值仅用于维护者核对上游未修改文件。
2. 使用上游源码中的 `docs/packaging.md`、`.github/workflows/release.yml` 和 `nativefiles/`。macOS 使用 Xcode 命令行工具；Windows 使用发行流程所列的 MSYS2 工具链。两平台均需 Meson、Ninja、CMake 和标准编译工具。按对应架构的发行配置初始化 `build` 目录，再运行 `meson compile -C build vendor/adb:executable`。Windows 还需要同构建树中的 `AdbWinApi.dll` 和 `AdbWinUsbApi.dll`。
3. 退出 Screen Annex 后，可用 `HOSMIRROR_ADB` 指定修改后的 `adb` 或 `adb.exe` 绝对路径，或替换可写 App 副本中 `Resources/scrcpy/<对应平台>/` 里的 ADB 文件。macOS 可对修改过的 ADB 和 App 副本重新进行本地临时签名。ADB 的启动路径接受用户自己的构建。

Windows 的公开分发应保留整个发行目录，包括 `Source Code`。macOS DMG 已包含对应源码，用户按正常流程安装 `.app` 即可。
