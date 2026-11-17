#!/bin/bash
# 使用 libusb 自带的 Xcode 配置生成 Darwin 静态库。
set -euo pipefail
SOURCE="${1:?请提供 libusb 源码目录}"
PREFIX="${2:?请提供静态库安装目录}"
BUILD="${3:?请提供对象文件目录}"
ARCH="$(uname -m)" # 在 Rosetta 终端中也使用目标架构，避免 xcrun 选择宿主架构。
mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include/libusb-1.0" "$BUILD"

OBJECTS=()
for FILE in core descriptor hotplug io strerror sync os/events_posix os/threads_posix os/darwin_usb; do
    # 源文件列表来自上游 libusb/Makefile.am 的 POSIX 和 Darwin 分支。
    OBJECT="$BUILD/$(basename "$FILE").o"
    xcrun clang -arch "$ARCH" -O2 -fvisibility=hidden -I"$SOURCE/Xcode" -I"$SOURCE/libusb" \
        -c "$SOURCE/libusb/$FILE.c" -o "$OBJECT"
    OBJECTS+=("$OBJECT")
done
xcrun libtool -static -o "$PREFIX/lib/libusb-1.0.a" "${OBJECTS[@]}"
cp "$SOURCE/libusb/libusb.h" "$PREFIX/include/libusb-1.0/libusb.h"

# 依据 libusb-1.0.pc.in 提供头文件和静态链接所需的 macOS 框架。
cat > "$PREFIX/lib/pkgconfig/libusb-1.0.pc" <<'PC'
prefix=${pcfiledir}/../..
Name: libusb-1.0
Description: C API for USB device access
Version: 1.0.30
Libs: -L${prefix}/lib -lusb-1.0
Libs.private: -lobjc -framework IOKit -framework CoreFoundation -framework Security
Cflags: -I${prefix}/include/libusb-1.0
PC
