#!/bin/bash
# Builds Screen Annex.app and packages it into a compressed DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
DIST="${HOSMIRROR_DIST_DIR:-dist}" # 与 App 构建入口共用可选输出目录。
APP="$DIST/Screen Annex.app"

if [[ $# -gt 2 || ( $# -eq 2 && ( $1 != --no-build || $2 != --separate-adb-source && $2 != --separate-sources ) ) ]]; then
  echo "usage: $0 [--no-build [--separate-adb-source|--separate-sources]]" >&2; exit 2
fi
# 正常打包先构建；公证和公开构建流程显式保留已验证的 App。
case "${1:-}" in
  "") ./scripts/build-app.sh ;; # 普通入口继续生成最新 App。
  --no-build) test -d "$APP" ;; # 只封装现有 App，保留其签名。
  *) echo "usage: $0 [--no-build [--separate-adb-source|--separate-sources]]" >&2; exit 2 ;;
esac
if ! python3 -c 'import dmgbuild' 2>/dev/null; then
  echo 'Install the DMG packaging tool with: python3 -m pip install dmgbuild==1.6.7' >&2
  exit 1
fi
case "$(uname -m)" in arm64) ANDROID_PLATFORM=macos-aarch64 ;; x86_64) ANDROID_PLATFORM=macos-x86_64 ;; *) exit 1 ;; esac # 不把其他架构的旧产物误当成本机构建。
SOURCE_ARGS=()
if [[ ${2:-} == --separate-sources ]]; then
  SOURCE_ARGS+=(--separate-sources) # 确认镜像中的 App 确实使用对应源码单独交付的模式。
fi
python3 scripts/vendor_scrcpy.py verify --resources "$APP/Contents/Resources" --platform "$ANDROID_PLATFORM" --signed "${SOURCE_ARGS[@]+${SOURCE_ARGS[@]}}" # 检查实际打包的运行文件和许可材料。

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/Screen Annex-${VERSION}.dmg"

DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hosmirror-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT # 正常完成和中途失败都回收本次专用暂存目录。
LAYOUT_ARGS=(-D "app=$APP") # dmgbuild 使用 ditto 拷贝 App，保留现有签名。
if [[ $# -lt 2 ]]; then
  python3 scripts/vendor_scrcpy.py adb-source --destination "$DMG_STAGING_DIR/Source Code" # 单独分发 DMG 时带上对应源码。
  LAYOUT_ARGS+=(-D "source=$DMG_STAGING_DIR/Source Code")
fi
# 在自动构建中直接写入 Finder 布局，无需启动 Finder。
python3 -m dmgbuild -s scripts/dmg-layout.py "${LAYOUT_ARGS[@]}" "Screen Annex" "$DMG_STAGING_DIR/Screen Annex.dmg"
mv -f "$DMG_STAGING_DIR/Screen Annex.dmg" "$DMG"

echo "==> $DMG"
du -sh "$DMG"
