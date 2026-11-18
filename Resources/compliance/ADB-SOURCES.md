# ADB 对应源码和重新链接

Screen Annex 随包分发的是从 AOSP 源码构建的 `android-tools-static` 36.0.1。macOS 使用 universal2 `adb`，Windows x64 使用 `adb.exe` 和同一发行版的 `AdbWinApi.dll`、`AdbWinUsbApi.dll`。原始版本、归档和文件的 SHA-256 记录在 `scrcpy.lock.json`。ADB 和 scrcpy 是独立程序。

在 [GitHub Releases](https://github.com/farceli/screen-annex/releases) 打开与 App 版本一致的页面，下载 `Screen-Annex-corresponding-source.zip`。解压后进入 `Source Code/ADB/`。独立交付的 ADB 源码也可直接位于 `Source Code/`。该目录包含上游 `android-tools-static-36.0.1-src-windows.zip` 和 `packagecache/`。源包适用于两平台，并包含 Windows USB DLL 的源码。`packagecache/` 收录了发行构建选用的 Meson Wrap 源码和补丁。它们连同源包中的 Meson 配方用于重新链接静态库（包括 libusb 1.0.29）。许可和归属原文在 `licenses/ADB-NOTICES.txt` 以及各源码归档中。Windows 的 GCC 16.1.0 运行库适用 GCC Runtime Library Exception。

1. 解开源码 ZIP，将 `packagecache/` 复制到解包后的 `subprojects/packagecache/`。可以先修改 libusb 的对应源码，或按 Meson Wrap 的规则提供本地修改后的库。原始校验值仅用于维护者核对上游未修改文件。
2. 使用上游源码中的 `docs/packaging.md`、`.github/workflows/release.yml` 和 `nativefiles/`。macOS 使用 Xcode 命令行工具；Windows 使用发行流程所列的 MSYS2 工具链。两平台均需 Meson、Ninja、CMake 和标准编译工具。按对应架构的发行配置初始化 `build` 目录，再运行 `meson compile -C build vendor/adb:executable`。Windows 还需要同构建树中的 `AdbWinApi.dll` 和 `AdbWinUsbApi.dll`。
3. 退出 Screen Annex 后，可用 `HOSMIRROR_ADB` 指定修改后的 `adb` 或 `adb.exe` 绝对路径，或替换可写 App 副本中 `Resources/scrcpy/<对应平台>/` 里的 ADB 文件。macOS 可对修改过的 ADB 和 App 副本重新进行本地临时签名。ADB 的启动路径接受用户自己的构建。

独立于 GitHub Release 交付软件包时，请在相同分发位置提供所有对应源码，或随包提供完整材料。用户运行软件时只需下载平台应用包。
