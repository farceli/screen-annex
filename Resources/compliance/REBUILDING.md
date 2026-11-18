# 对应源码、重新链接与本机替换

在 [GitHub Releases](https://github.com/farceli/screen-annex/releases) 打开与 App 版本一致的页面，下载 `Screen-Annex-corresponding-source.zip`。解压后在 `Source Code/scrcpy/` 找到完整 scrcpy、FFmpeg、libusb、SDL 和 dav1d 源码、补丁及脚本。离线分发包可在本目录直接提供相同材料。`sources/` 中的版本与 `scrcpy.lock.json` 一致，上游 `app/deps` 下的脚本保存源归档摘要和构建参数。

macOS 版 scrcpy 静态链接 FFmpeg 和 libusb。GitHub 发布按 LGPL 2.1 第 6(d) 条，在同一 Release 提供第 6(a) 条所述材料，使用户能够修改库并重新链接独立 scrcpy 程序。

## 构建环境

macOS：在目标架构的 Mac 上安装 Xcode Command Line Tools、C/C++ 编译器、make、CMake、Meson、Ninja、pkg-config、NASM（Intel）、wget、Perl 和 Python 3。macOS SDK 和系统 zlib 来自系统工具链。FFmpeg 的上游脚本包含 Homebrew zlib 的搜索路径，可根据本机工具链调整为相应系统 zlib 路径。

Windows x64：使用 Linux 上的 MinGW-w64 交叉编译环境，另备上述构建工具和交叉目标的 zlib 开发文件。上游 release/build_windows.sh 和 cross_win64.txt 保存目标配置。Windows 运行时使用可替换 FFmpeg 与 libusb DLL；不要求用户重建 Screen Annex 的 WinUI 或 Rust 鸿蒙内核。

## 构建与重新链接

运行同目录 rebuild_scrcpy.sh，参数为 macos 或 windows-x86_64，第二个参数为新建的工作目录。Windows 构建应用 `scrcpy-windows-events.patch`；macOS 构建应用 `scrcpy-macos-titlebar.patch`，并使用 `build_libusb_macos.sh` 按上游 Xcode 配置构建 libusb 静态库。依赖脚本使用本目录预置归档，保持上游 FFmpeg 构建选项。保留随包的同版本 scrcpy-server 和 ADB。

如果需要修改 LGPL 库，先让脚本完成解包，修改工作目录 scrcpy-5.0.1/app/deps/work/sources 下相应源码，再在相同工作目录重新运行脚本。脚本保留已展开源码和构建目录。修改构建配置时，可检查完整上游 release/build_macos.sh、release/build_windows.sh、app/deps/ffmpeg.sh 和 app/deps/libusb.sh。不能为了重新构建而删去依赖的原始声明。

输出是工作目录中的 hosmirror-relink/app/scrcpy（macOS）或 hosmirror-relink/app/scrcpy.exe（Windows）；Windows DLL 位于 app/deps/work/install/win64-cross-shared/bin。静态 macOS 重新链接会直接把用户修改后的库链接进输出。上游编译脚本中没有给用户施加“禁止修改、禁止重链接”的限制。

## 替换本机副本

退出 Screen Annex 后，复制 App 到自己可写的目录。macOS 替换副本的 Contents/Resources/scrcpy/对应平台/scrcpy；Windows 替换 Resources/scrcpy/windows-x86_64 下的 scrcpy.exe 或所修改的兼容 DLL。保留同版本的 scrcpy-server、图标及其余所需运行文件。

macOS 本地副本因资源变化会失去原签名。用户可用系统 codesign 对修改后的 scrcpy 和 App 副本重新执行 ad-hoc 签名；不需要 Screen Annex 的 Developer ID 私钥。官方更新会覆盖用户修改，所以请保留个人副本和源码。生产发布脚本的原始校验是维护者的发布检查，不是 App 的运行时限制；App 不验证官方哈希或拒绝用户重新链接的版本。

## 验证边界

本次已经核对官方发布归档、依赖源码摘要、版本脚本及随包材料。`rebuild_scrcpy.sh` 使用配套归档构建。 逐字节复现上游二进制尚未在所有目标平台验证。一般用途编译器、系统 SDK、汇编器和包管理器由使用者准备。

ADB 的独立构建与替换见 [ADB-SOURCES.md](ADB-SOURCES.md)。scrcpy 所用 zlib 由工具链提供，声明另附。
