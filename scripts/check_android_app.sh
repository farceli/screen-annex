#!/bin/bash
# 直接编译生产窗口，使用测试状态比较鸿蒙与 Android 的原生窗口行为。
set -euo pipefail # 编译、进程检查或截图任意失败都停止。
cd "$(dirname "$0")/.." # 固定项目根目录，不依赖调用位置。
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang" # 所有编译缓存留在项目目录。
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/swift" # 不写入用户级 Swift 缓存。
FLAGS=(--disable-sandbox --cache-path .build/cache --scratch-path .build/scratch) # 与项目常规构建使用相同路径。
swift build -c debug "${FLAGS[@]}" # 先确保被测试的核心模块是当前源码。
PRODUCTS="$(swift build -c debug "${FLAGS[@]}" --show-bin-path)" # 从 SwiftPM 读取真实输出目录。
APP_SOURCES=() # 测试使用产品视图与控制器，不使用产品的 @main 自动枚举入口。
for SOURCE in Sources/HosMirrorApp/*.swift Sources/HosMirrorApp/Features/*.swift; do # 保留真实产品代码，不复制其实现。
    if [[ "$SOURCE" != Sources/HosMirrorApp/HosMirrorApp.swift ]]; then APP_SOURCES+=("$SOURCE"); fi # 由专用测试 main 提供入口。
done # 收集完成后再一次编译。
swiftc -disable-sandbox -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" -I "$PRODUCTS" "$PRODUCTS/HosMirrorCore.o" "${APP_SOURCES[@]}" Tests/MacAndroidIntegration.swift -o .build/android-ui-check # 使用本机架构，不需要模拟器或真机。
if [[ "${1:-}" == --screen-link ]]; then
    FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/hosmirror-screen-link.XXXXXX")"
    trap 'rm -rf "$FIXTURE"' EXIT # 只清理本次生成的命令替身和日志。
    case "$(uname -m)" in arm64) ARCH=macos-aarch64 ;; x86_64) ARCH=macos-x86_64 ;; *) exit 1 ;; esac
    mkdir -p "$FIXTURE/tools" "$FIXTURE/scrcpy/$ARCH"
    export HOSMIRROR_RESOURCES="$FIXTURE" HOSMIRROR_SCREEN_LINK_LOG="$FIXTURE/commands.log"
    export HOSMIRROR_HARMONY_RESOURCES="$FIXTURE" HOSMIRROR_ADB="$FIXTURE/scrcpy/$ARCH/adb" # 强制使用替身，覆盖调用者已配置的 SDK。
    cat > "$FIXTURE/tools/hdc" <<'EOF'
#!/bin/sh
# 记录调用并模拟锁屏服务和手机端命令退出码。
printf '%s\n' "hdc $*" >> "$HOSMIRROR_SCREEN_LINK_LOG"
case "$*" in
    *'hidumper -s ScreenlockService'*) printf '* screenLocked\ttrue\t100\n' ;;
    *'HOSMIRROR_COMMAND_EXIT'*) printf 'HOSMIRROR_COMMAND_EXIT:0\n' ;;
esac
EOF
    cat > "$FIXTURE/scrcpy/$ARCH/adb" <<'EOF'
#!/bin/sh
# 记录锁屏、唤醒及系统解锁请求，不访问真实手机。
printf '%s\n' "adb $*" >> "$HOSMIRROR_SCREEN_LINK_LOG"
EOF
    chmod 755 "$FIXTURE/tools/hdc" "$FIXTURE/scrcpy/$ARCH/adb"
fi
.build/android-ui-check "$@" # 可用 --video-only 仅回放视频夹具，不执行真实设备命令。
