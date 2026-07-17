#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

swift build --package-path "$ROOT" -c release

ICON_BUILD_DIR="$ROOT/.build/codex-quick-ok-app-icon"
ICONSET="$ICON_BUILD_DIR/AppIcon.iconset"
rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"
"$ROOT/scripts/render-app-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"

rm -rf "$ROOT/dist"
APP="$ROOT/dist/Codex 可.app"
PLUGIN="$ROOT/dist/marketplace/plugins/codex-quick-ok"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PLUGIN/bin"
cp "$ROOT/.build/release/CodexQuickOKApp" "$APP/Contents/MacOS/CodexQuickOKApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cp -R "$ROOT/plugin/codex-quick-ok/." "$PLUGIN/"
cp "$ROOT/.build/release/CodexQuickOKHook" "$PLUGIN/bin/CodexQuickOKHook"

mkdir -p "$ROOT/dist/marketplace/.agents/plugins"
cp "$ROOT/marketplace/.agents/plugins/marketplace.json" \
  "$ROOT/dist/marketplace/.agents/plugins/marketplace.json"

test -s "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
