#!/bin/bash
# 使用随包完整源码重新链接独立 scrcpy，不执行或替换已安装应用。
set -eo pipefail # 任意编译失败立即停止；兼容上游脚本未开启 nounset 的环境。
MATERIALS="$(cd "$(dirname "$0")" && pwd)" # 固定材料目录，允许用户从其他工作目录执行。
TARGET="${1:-macos}" # 默认构建当前 Mac 的原生架构。
WORK="${2:?请提供一个新的可写构建目录作为第二个参数}" # 避免在 App 包内直接展开和修改源码。
case "$TARGET" in macos|windows-x86_64) ;; *) echo "仅支持 macos 或 windows-x86_64" >&2; exit 2 ;; esac # 不猜测目标工具链。
mkdir -p "$WORK" # 创建用户明确指定的目录，不删除任何已有源码。
WORK="$(cd "$WORK" && pwd)" # 将后续路径统一转成绝对路径。
if [ ! -d "$WORK/scrcpy-5.0.1" ]; then tar xf "$MATERIALS/sources/scrcpy-v5.0.1-source.tar.gz" -C "$WORK"; fi # 保留用户已修改的 scrcpy 源码。
cd "$WORK/scrcpy-5.0.1" # 使用上游完整工程，不需要 HosMirror 的专有代码。
if [ "$TARGET" = macos ]; then
    # 已应用时保留用户对展开源码的进一步修改。
    if [ ! -f app/src/sys/macos/hosmirror_titlebar.m ]; then
        patch -p1 < "$MATERIALS/scrcpy-macos-titlebar.patch"
    fi
    export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
else
    # 已应用时保留用户对展开源码的进一步修改。
    if ! grep -q HOSMIRROR_WINDOWS_EVENTS app/src/screen.c; then
        patch -p1 < "$MATERIALS/scrcpy-windows-events.patch"
    fi
fi
mkdir -p app/deps/work/sources # 预置上游脚本使用的归档缓存。
for ARCHIVE in ffmpeg-9.0.2.tar.xz sdl-3.4.18.tar.gz dav1d-1.5.4.tar.xz libusb-1.0.30.tar.gz; do # 库的完整源码均来自随包材料。
    cp "$MATERIALS/sources/$ARCHIVE" "app/deps/work/sources/$ARCHIVE" # 上游脚本会再次验证自身记录的 SHA-256。
done # 不改写已展开的库源码，便于用户修改后再次构建。
if [ "$TARGET" = macos ]; then HOST=macos; KIND=native; LINK=static; else HOST=win64; KIND=cross; LINK=shared; fi # 与官方平台链接方式一致。
for DEPENDENCY in sdl dav1d ffmpeg; do # 按依赖顺序先构建库，再链接使用这些库的 scrcpy。
    bash "app/deps/$DEPENDENCY.sh" "$HOST" "$KIND" "$LINK" # 执行源码归档中原样提供的上游构建脚本。
done # 所有上游脚本与其配置均保存在 scrcpy 完整源码包内。
INSTALL="$PWD/app/deps/work/install/$HOST-$KIND-$LINK" # 固定本次构建得到的库路径。
if [ "$TARGET" = macos ]; then
    USB_SOURCE="$PWD/app/deps/work/sources/libusb-1.0.30"
    if [ ! -d "$USB_SOURCE" ]; then tar xf "$MATERIALS/sources/libusb-1.0.30.tar.gz" -C "$(dirname "$USB_SOURCE")"; fi
    bash "$MATERIALS/build_libusb_macos.sh" "$USB_SOURCE" "$INSTALL" "$WORK/libusb-objects"
else
    bash app/deps/libusb.sh "$HOST" "$KIND" "$LINK"
fi
unset PKG_CONFIG_PATH # 不意外链接另一套已安装 FFmpeg 或 libusb。
export PKG_CONFIG_LIBDIR="$INSTALL/lib/pkgconfig" # 仅从本次构建目录发现第三方库。
OPTIONS=("-Dc_args=-I$INSTALL/include" "-Dc_link_args=-L$INSTALL/lib" --buildtype=release -Dcompile_server=false -Dportable=true) # 与上游客户端构建选项一致，server 沿用同版本二进制。
if [ "$TARGET" = macos ]; then OPTIONS+=(-Dstatic=true --strip -Db_lto=true); else OPTIONS+=(--cross-file=cross_win64.txt); fi # macOS 沿用官方发行客户端的静态链接和优化选项。
if [ -d hosmirror-relink ]; then meson setup --reconfigure hosmirror-relink "${OPTIONS[@]}"; else meson setup hosmirror-relink "${OPTIONS[@]}"; fi # 修改库后可重复构建而不删除个人修改。
ninja -C hosmirror-relink # 完成使用修改后 LGPL 库的客户端重新链接。
echo "重新链接完成：$PWD/hosmirror-relink/app/；替换本机副本的方法见 REBUILDING.md。" # 不自动触碰用户正在使用的 App。
