#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"
LOGIN_KEYCHAIN="${CODEX_QUICK_OK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SECURITY="${CODEX_QUICK_OK_SECURITY:-/usr/bin/security}"
CODESIGN="${CODEX_QUICK_OK_CODESIGN:-/usr/bin/codesign}"
BUNDLE_IDENTIFIER="com.codexquickok.CodexQuickOK"

identity_hashes=()
while IFS= read -r line; do
  [[ "$line" == *') '*'"'* ]] || continue
  remainder="${line#*) }"
  sha1="${remainder%% *}"
  common_name="${line#*\"}"
  common_name="${common_name%%\"*}"
  if [[ "$common_name" == "$SIGNING_IDENTITY_NAME" && ${#sha1} -eq 40 && "$sha1" != *[^[:xdigit:]]* ]]; then
    identity_hashes+=("$sha1")
  fi
done < <("$SECURITY" find-identity -v -p codesigning "$LOGIN_KEYCHAIN")

if (( ${#identity_hashes} != 1 )); then
  print -u2 -- "No unique valid code-signing identity named \"$SIGNING_IDENTITY_NAME\"."
  print -u2 -- "Run: zsh \"$ROOT/scripts/setup-local-signing.sh\""
  exit 78
fi
identity_sha1="${identity_hashes[1]}"
DESIGNATED_REQUIREMENT_EXPRESSION="identifier \"$BUNDLE_IDENTIFIER\" and certificate leaf = H\"$identity_sha1\""
DESIGNATED_REQUIREMENT="designated => $DESIGNATED_REQUIREMENT_EXPRESSION"

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
"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" --requirements "=$DESIGNATED_REQUIREMENT" "$APP"
"$CODESIGN" --verify --deep --strict --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$APP"
