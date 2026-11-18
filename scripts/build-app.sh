#!/bin/bash
# Build the app with its Android runtime. HarmonyOS SDK files are loaded locally at runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="${HOSMIRROR_DIST_DIR:-dist}/Screen Annex.app" # 可在独立目录构建，避免覆盖正在运行的 App。
case "$(uname -m)" in arm64) ANDROID_PLATFORM=macos-aarch64 ;; x86_64) ANDROID_PLATFORM=macos-x86_64 ;; *) echo "不支持的 macOS 架构" >&2; exit 1 ;; esac # 与当前 Swift 原生构建使用相同架构。
if [[ ! -d Resources/scrcpy || ! -f Resources/compliance/scrcpy.lock.json ]]; then
  echo "请先运行 python3 scripts/vendor_scrcpy.py install --download" >&2 # 首次克隆时显式准备第三方运行文件。
  exit 1
fi
python3 scripts/vendor_scrcpy.py verify # 先校验本机资源，再替换旧 App。

export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
export SWIFT_MODULE_CACHE_PATH="$PWD/.build/swift"
FLAGS=(--disable-sandbox --cache-path .build/cache --scratch-path .build/scratch)
if [[ ${SCREEN_ANNEX_ANDROID_RELEASE:-0} == 1 ]]; then
  FLAGS+=(-Xswiftc -DANDROID_RELEASE) # 公开包仅显示 Android 设备和对应设置。
fi
mkdir -p .build/tmp .build/clang .build/swift

# Swift Build 可能把部署下限同时写成链接 SDK。显式记录实际 SDK，让 AppKit 采用与 scrcpy 一致的标题栏度量。
MACOS_LINK_SDK="$(xcrun --sdk macosx --show-sdk-version)"
LINK_FLAGS=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$MACOS_LINK_SDK") # 保持 Package.swift 的 macOS 14 部署下限。

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product HosMirror -debug-info-format none "${FLAGS[@]}" "${LINK_FLAGS[@]}" # 应用包只需主程序，无需构建探针或生成调试符号。

BIN="$(swift build -c "$CONFIG" "${FLAGS[@]}" --show-bin-path)/HosMirror"
test -x "$BIN"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/HosMirror"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/HarmonyMirror.icns "$APP/Contents/Resources/" # 系统从 Bundle 读取鸿蒙投屏图标。

# 设置使用独立的 Launch Services 身份，作为内置 App 随主程序一起安装。
SETTINGS_APP="$APP/Contents/Helpers/Screen Annex Settings.app"
mkdir -p "$SETTINGS_APP/Contents/MacOS"
cp "$BIN" "$SETTINGS_APP/Contents/MacOS/HosMirrorSettings"
cp Resources/SettingsPanel-Info.plist "$SETTINGS_APP/Contents/Info.plist"

SOURCE_ARGS=()
if [[ ${SCREEN_ANNEX_SEPARATE_SOURCES:-0} == 1 ]]; then
  SOURCE_ARGS+=(--separate-sources) # 公开 Release 将完整源码和重新链接材料单独上传。
fi
cp LICENSE "$APP/Contents/Resources/LICENSE" # 在发行包中保留项目自身的许可文本。
python3 scripts/vendor_scrcpy.py stage --platform "$ANDROID_PLATFORM" --destination "$APP/Contents/Resources" "${SOURCE_ARGS[@]+${SOURCE_ARGS[@]}}" # Android 运行文件只复制当前平台。

echo "==> ad-hoc sign"
for tool in scrcpy adb; do
  binary="$APP/Contents/Resources/scrcpy/$ANDROID_PLATFORM/$tool"
  # 已锁定且验证通过的签名可以原样保留，避免不同 macOS 版本改写 Mach-O 签名布局。
  if ! codesign --verify --strict "$binary" 2>/dev/null; then
    codesign --force --sign - "$binary"
  fi
done
codesign --force --sign - "$SETTINGS_APP" # 先签嵌套设置 App，再封签外层。
codesign --force --sign - "$APP" # 内置工具和子 App 已逐一校验，再封签外层。
codesign --verify --deep --strict "$APP" # 构建产物必须通过本地签名完整性检查。
python3 scripts/vendor_scrcpy.py verify --resources "$APP/Contents/Resources" --platform "$ANDROID_PLATFORM" --signed "${SOURCE_ARGS[@]+${SOURCE_ARGS[@]}}" # 核对最终签名后的 ADB 和 scrcpy 代码内容。

echo "==> done: $APP"
du -sh "$APP"
