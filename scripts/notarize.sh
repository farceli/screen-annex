#!/bin/bash
# Signs, notarizes and staples the app / DMG.
#
# Required environment:
#   DEVELOPER_ID   "Developer ID Application: Your Name (TEAMID)"
#   APPLE_ID       Apple account email
#   TEAM_ID        Apple team id
#   APP_PASSWORD   app-specific password
set -euo pipefail
cd "$(dirname "$0")/.."

DIST="${HOSMIRROR_DIST_DIR:-dist}" # 与构建和打包使用同一个输出目录。
APP="$DIST/Screen Annex.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
DMG="$DIST/Screen Annex-${VERSION}.dmg"

: "${DEVELOPER_ID:?set DEVELOPER_ID}"
: "${APPLE_ID:?set APPLE_ID}"
: "${TEAM_ID:?set TEAM_ID}"
: "${APP_PASSWORD:?set APP_PASSWORD}"

# 必须先构建，再正式签名；后续封装阶段不能再调用构建脚本。
./scripts/build-app.sh

echo "==> codesign (hardened runtime)"
case "$(uname -m)" in arm64) ANDROID_PLATFORM=macos-aarch64 ;; x86_64) ANDROID_PLATFORM=macos-x86_64 ;; *) exit 1 ;; esac # 选择本次构建交付的平台。
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Resources/scrcpy/$ANDROID_PLATFORM/scrcpy" # 先用显式指定的正式身份封签客户端。
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Resources/scrcpy/$ANDROID_PLATFORM/adb" # 公证前以同一身份封签内置 ADB。
codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP/Contents/Helpers/Screen Annex Settings.app"
codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> dmg"
./scripts/package-dmg.sh --no-build # 保留上一步验证通过的正式签名。
codesign --force --timestamp --sign "$DEVELOPER_ID" "$DMG"

echo "==> notarize"
# 保存结构化结果并核验 Accepted，不能只依赖 notarytool 的进程退出状态。
NOTARY_RESULT="$(mktemp -t hosmirror-notary)" # 临时文件只保存公证结果，不保存账号密码。
trap 'rm -f "$NOTARY_RESULT"' EXIT # 成功和失败都清理临时结果文件。
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait --output-format json > "$NOTARY_RESULT" # 等待服务端完成审核。
if [ "$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT")" != "Accepted" ]; then
  cat "$NOTARY_RESULT" >&2 # 失败时保留官方返回的原因供排查。
  exit 1 # 不对未通过公证的镜像继续 staple。
fi

echo "==> staple"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" # Gatekeeper 验证失败必须让发布流程失败。
echo "==> done: $DMG"
