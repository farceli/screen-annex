#!/bin/bash
# Builds Screen Annex.app and packages it into a compressed DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
DIST="${HOSMIRROR_DIST_DIR:-dist}" # 与 App 构建入口共用可选输出目录。
APP="$DIST/Screen Annex.app"

# 正常打包先构建；公证流程显式跳过构建，保留已经验证的 Developer ID 签名。
case "${1:-}" in
  "") ./scripts/build-app.sh ;; # 普通入口继续生成最新 App。
  --no-build) test -d "$APP" ;; # 只封装现有 App，保留其签名。
  *) echo "usage: $0 [--no-build]" >&2; exit 2 ;; # 拒绝拼错的参数，避免意外覆盖签名。
esac
case "$(uname -m)" in arm64) ANDROID_PLATFORM=macos-aarch64 ;; x86_64) ANDROID_PLATFORM=macos-x86_64 ;; *) exit 1 ;; esac # 不把其他架构的旧产物误当成本机构建。
python3 scripts/vendor_scrcpy.py verify --resources "$APP/Contents/Resources" --platform "$ANDROID_PLATFORM" --signed # 检查实际打包的运行文件和许可材料。

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$DIST/Screen Annex-${VERSION}.dmg"

DMG_STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hosmirror-dmg.XXXXXX")" # 镜像源目录必须包含完整的 App 包。
trap 'rm -rf "$DMG_STAGING_DIR"' EXIT # 正常完成和中途失败都回收本次专用暂存目录。
ditto "$APP" "$DMG_STAGING_DIR/Screen Annex.app" # 保留签名、权限与包层级。
python3 scripts/vendor_scrcpy.py adb-source --destination "$DMG_STAGING_DIR/Source Code" # 对应源码随镜像分发，用户拖入 App 时无需复制源码。
rm -f "$DMG"
# macOS 26+ recommends `diskutil image create from`; hdiutil is the fallback.
if ! diskutil image create from --volumeName "Screen Annex" --format UDZO \
    "$DMG_STAGING_DIR" "$DMG" >/dev/null 2>&1; then # 从父目录封装，防止把 Contents 直接写到镜像根目录。
  hdiutil create -volname "Screen Annex" -srcfolder "$DMG_STAGING_DIR" \
    -ov -format UDZO "$DMG" >/dev/null
fi

echo "==> $DMG"
du -sh "$DMG"
