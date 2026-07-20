#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"
LOGIN_KEYCHAIN="${CODEX_QUICK_OK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SECURITY="${CODEX_QUICK_OK_SECURITY:-/usr/bin/security}"
CODESIGN="${CODEX_QUICK_OK_CODESIGN:-/usr/bin/codesign}"
BUNDLE_IDENTIFIER="com.codexquickok.CodexQuickOK"
DIST_DIR="${CODEX_QUICK_OK_DIST_DIR:-$ROOT/dist}"
BUILD_PRODUCT="${CODEX_QUICK_OK_BUILD_PRODUCT:-$ROOT/.build/release/CodexQuickOKApp}"
SWIFT="${CODEX_QUICK_OK_SWIFT:-swift}"
ICON_RENDERER="${CODEX_QUICK_OK_ICON_RENDERER:-$ROOT/scripts/render-app-icon.swift}"
ICONUTIL="${CODEX_QUICK_OK_ICONUTIL:-iconutil}"
MKTEMP="${CODEX_QUICK_OK_MKTEMP:-mktemp}"
MV="${CODEX_QUICK_OK_MV:-mv}"
STAGING_ROOT=""
BACKUP_APP=""
PUBLISHED_APP=""
PUBLISH_COMMITTED=false

cleanup() {
  if [[ "$PUBLISH_COMMITTED" != true && -n "$BACKUP_APP" && -e "$BACKUP_APP" \
      && -n "$PUBLISHED_APP" && ! -e "$PUBLISHED_APP" ]]; then
    "$MV" "$BACKUP_APP" "$PUBLISHED_APP" || true
  fi
  [[ -z "$STAGING_ROOT" || ! -d "$STAGING_ROOT" ]] || rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

identity_hashes=()
if ! identity_output="$("$SECURITY" find-identity -v -p codesigning "$LOGIN_KEYCHAIN")"; then
  print -u2 -- 'Unable to query code-signing identities from the login keychain.'
  exit 70
fi
while IFS= read -r line; do
  [[ "$line" == *') '*'"'* ]] || continue
  remainder="${line#*) }"
  sha1="${remainder%% *}"
  common_name="${line#*\"}"
  common_name="${common_name%%\"*}"
  if [[ "$common_name" == "$SIGNING_IDENTITY_NAME" && ${#sha1} -eq 40 && "$sha1" != *[^[:xdigit:]]* ]]; then
    identity_hashes+=("$sha1")
  fi
done <<< "$identity_output"

if (( ${#identity_hashes} != 1 )); then
  print -u2 -- "No unique valid code-signing identity named \"$SIGNING_IDENTITY_NAME\"."
  print -u2 -- "Run: zsh \"$ROOT/scripts/setup-local-signing.sh\""
  exit 78
fi
identity_sha1="${identity_hashes[1]}"
DESIGNATED_REQUIREMENT_EXPRESSION="identifier \"$BUNDLE_IDENTIFIER\" and certificate leaf = H\"$identity_sha1\""
DESIGNATED_REQUIREMENT="designated => $DESIGNATED_REQUIREMENT_EXPRESSION"

"$SWIFT" build --package-path "$ROOT" -c release

ICON_BUILD_DIR="$ROOT/.build/codex-quick-ok-app-icon"
ICONSET="$ICON_BUILD_DIR/AppIcon.iconset"
rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"
"$ICON_RENDERER" "$ICONSET"
"$ICONUTIL" -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"

mkdir -p "$DIST_DIR"
STAGING_ROOT="$("$MKTEMP" -d "$DIST_DIR/.CodexQuickOK-build.XXXXXX")"
APP="$STAGING_ROOT/Codex 可.app"
PUBLISHED_APP="$DIST_DIR/Codex 可.app"
BACKUP_APP="$DIST_DIR/.Codex 可.app.backup.$$"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_PRODUCT" \
  "$APP/Contents/MacOS/CodexQuickOKApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" \
  "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
cp "$ICON_BUILD_DIR/AppIcon.icns" \
  "$APP/Contents/Resources/AppIcon.icns"

test -s "$APP/Contents/Resources/AppIcon.icns"
"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" --requirements "=$DESIGNATED_REQUIREMENT" "$APP"
"$CODESIGN" --verify --deep --strict --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$APP"

had_existing=false
if [[ -e "$PUBLISHED_APP" ]]; then
  "$MV" "$PUBLISHED_APP" "$BACKUP_APP"
  had_existing=true
fi
if ! "$MV" "$APP" "$PUBLISHED_APP"; then
  if [[ "$had_existing" == true && -e "$BACKUP_APP" ]]; then
    "$MV" "$BACKUP_APP" "$PUBLISHED_APP"
  fi
  print -u2 -- 'Unable to publish the verified release bundle; previous release restored.'
  exit 74
fi
PUBLISH_COMMITTED=true
if [[ "$had_existing" == true ]]; then
  rm -rf "$BACKUP_APP"
fi
