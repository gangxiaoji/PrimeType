#!/usr/bin/env bash
# 构建 PrimeType.app + PrimeTypeInstaller.app，并打包成 dmg。
# 用法：./scripts/build_dmg.sh [arm64|x86_64]，默认 arm64。
# 前置条件：Vendor/librime/dist 已就位（CI 里由 scripts/build_librime.sh 生成；
# 本地先跑一次 ./scripts/build_librime.sh）；Intel 构建前还需 ./scripts/build_opus.sh。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCH="${1:-arm64}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "usage: $0 [arm64|x86_64]" >&2; exit 1 ;;
esac

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Sources/InputType/Info.plist)"
DERIVED_DATA="$ROOT_DIR/build/DerivedData"
OUT_DIR="$ROOT_DIR/build/release"
mkdir -p "$OUT_DIR"

echo "==> Generating Xcode project..."
xcodegen generate

echo "==> Building PrimeTypeSettings.app Helper (Release, $ARCH)..."
# SWIFT_COMPILATION_MODE=singlefile：CI 上 Whole Module Optimization 会卡死。
# 实测（run 45668194826）：PrimeTypeSettings 的 WMO 编译（-O，19 个文件一次编完，
# 含 LocalNeuralReranker/GrammarModelManager/VoiceASREngine）在 macos-15-intel runner
# 上 44 分钟零输出、被 45 分钟超时杀掉；上一轮同样位置卡了 3.5 小时。
# 单文件编译并行、快得多，产物仍是 Release -O，只是逐文件优化。
# SWIFT_OPTIMIZATION_LEVEL=-Onone：关优化，最后一招。
# 三轮全卡在 PrimeTypeSettings 编译 SettingsWindowController.swift（4446 行）那批文件上，
# 120 分钟零输出，编译器真挂起。关优化绕过优化器挂起；若卡在类型检查则仍无效。
# 产物是未优化的，仅供测试。
xcodebuild \
  -project InputType.xcodeproj \
  -scheme PrimeTypeSettings \
  -configuration Release \
  -arch "$ARCH" \
  SWIFT_COMPILATION_MODE=singlefile \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  -derivedDataPath "$DERIVED_DATA" \
  build

echo "==> Building PrimeType.app (Release, $ARCH)..."
xcodebuild \
  -project InputType.xcodeproj \
  -scheme InputType \
  -configuration Release \
  -arch "$ARCH" \
  SWIFT_COMPILATION_MODE=singlefile \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  -derivedDataPath "$DERIVED_DATA" \
  build

echo "==> Building PrimeTypeInstaller.app (Release, $ARCH)..."
xcodebuild \
  -project InputType.xcodeproj \
  -scheme PrimeTypeInstaller \
  -configuration Release \
  -arch "$ARCH" \
  SWIFT_COMPILATION_MODE=singlefile \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_HELPER="$DERIVED_DATA/Build/Products/Release/PrimeTypeSettings.app"
BUILT_IME="$DERIVED_DATA/Build/Products/Release/PrimeType.app"
BUILT_INSTALLER="$DERIVED_DATA/Build/Products/Release/PrimeTypeInstaller.app"

echo "==> Verifying built binary architecture..."
lipo -info "$BUILT_IME/Contents/MacOS/PrimeType"
file "$BUILT_IME/Contents/MacOS/PrimeType"

echo "==> Embedding PrimeTypeSettings.app inside PrimeType.app/Contents/Helpers/..."
mkdir -p "$BUILT_IME/Contents/Helpers"
rm -rf "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"
ditto "$BUILT_HELPER" "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"

SIGN_ID="${PRIMETYPE_SIGN_IDENTITY:-PrimeType Local Dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  codesign --force --deep --sign "$SIGN_ID" "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"
  codesign --force --deep --sign "$SIGN_ID" "$BUILT_IME"
else
  codesign --force --deep --sign - "$BUILT_IME/Contents/Helpers/PrimeTypeSettings.app"
  codesign --force --deep --sign - "$BUILT_IME"
fi

STAGE_DIR="$(mktemp -d /tmp/primetype-dmg-stage.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

STAGED_INSTALLER="$STAGE_DIR/PrimeTypeInstaller.app"
ditto "$BUILT_INSTALLER" "$STAGED_INSTALLER"
ditto "$BUILT_IME" "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$SIGN_ID\""; then
  echo "==> Signing embedded PrimeType.app and PrimeTypeInstaller.app with: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"
  codesign --force --sign "$SIGN_ID" "$STAGED_INSTALLER"
else
  echo "==> Ad-hoc signing PrimeTypeInstaller.app"
  codesign --force --deep --sign - "$STAGED_INSTALLER/Contents/Resources/PrimeType.app"
  codesign --force --sign - "$STAGED_INSTALLER"
fi

DMG_PATH="$OUT_DIR/PrimeType-v${VERSION}-macos-${ARCH}.dmg"
rm -f "$DMG_PATH"
echo "==> Creating DMG: $DMG_PATH"
hdiutil create \
  -volname "PrimeType" \
  -srcfolder "$STAGE_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

echo "==> Done! DMG ready:"
ls -lh "$DMG_PATH"
hdiutil imageinfo "$DMG_PATH" | grep -E "Format|Size" | head -4
