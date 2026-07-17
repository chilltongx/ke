#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
failures=0

fail() {
  print -u2 -- "FAIL: $1"
  failures=$((failures + 1))
}

expect_file() {
  [[ -f "$ROOT/$1" ]] || fail "missing $1"
}

expect_executable() {
  [[ -x "$ROOT/$1" ]] || fail "$1 is not executable"
}

expect_exact_line() {
  local file="$1"
  local line="$2"
  grep -Fxq -- "$line" "$ROOT/$file" || fail "$file is missing exact line: $line"
}

expect_absent_text() {
  local file="$1"
  local pattern="$2"
  if grep -Eq -- "$pattern" "$ROOT/$file"; then
    fail "$file contains forbidden text matching: $pattern"
  fi
}

for file in \
  Resources/Info.plist \
  Resources/PrivacyInfo.xcprivacy \
  marketplace/.agents/plugins/marketplace.json \
  scripts/build-release.sh \
  scripts/setup-local-signing.sh \
  scripts/install-local.sh \
  scripts/uninstall-local.sh \
  README.md; do
  expect_file "$file"
done

for script in scripts/build-release.sh scripts/setup-local-signing.sh scripts/install-local.sh scripts/uninstall-local.sh; do
  expect_executable "$script"
done

expect_file scripts/render-app-icon.swift
expect_executable scripts/render-app-icon.swift
expect_executable Tests/AppIconTests.sh
expect_executable Tests/SigningTests.sh

expect_exact_line .gitignore 'dist/'

if [[ -f "$ROOT/Resources/Info.plist" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT/Resources/Info.plist" 2>/dev/null)" == CodexQuickOKApp ]] || fail 'unexpected CFBundleExecutable'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist" 2>/dev/null)" == com.codexquickok.CodexQuickOK ]] || fail 'unexpected CFBundleIdentifier'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 'Codex 可' ]] || fail 'unexpected CFBundleName'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 0.1.0 ]] || fail 'unexpected short version'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Resources/Info.plist" 2>/dev/null)" == AppIcon ]] || fail 'CFBundleIconFile must be AppIcon'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 3 ]] || fail 'bundle version must be 3'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 14.0 ]] || fail 'unexpected minimum system version'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$ROOT/Resources/Info.plist" 2>/dev/null)" == true ]] || fail 'LSUIElement must be true'
fi

if [[ -f "$ROOT/Resources/PrivacyInfo.xcprivacy" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == false ]] || fail 'NSPrivacyTracking must be false'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == 'Array {'$'\n''}' ]] || fail 'collected data types must be empty'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == 'Array {'$'\n''}' ]] || fail 'accessed API types must be empty'
fi

if [[ -f "$ROOT/marketplace/.agents/plugins/marketplace.json" ]]; then
  python3 - "$ROOT/marketplace/.agents/plugins/marketplace.json" <<'PY' || fail 'marketplace metadata is not exact'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    actual = json.load(handle)

expected = {
    "name": "codex-quick-ok-local",
    "interface": {"displayName": "Codex Quick OK Local"},
    "plugins": [{
        "name": "codex-quick-ok",
        "source": {"source": "local", "path": "./plugins/codex-quick-ok"},
        "policy": {"installation": "AVAILABLE", "authentication": "ON_INSTALL"},
        "category": "Productivity",
    }],
}
raise SystemExit(0 if actual == expected else 1)
PY
fi

if [[ -f "$ROOT/scripts/build-release.sh" ]]; then
  expect_exact_line scripts/build-release.sh 'swift build --package-path "$ROOT" -c release'
  expect_exact_line scripts/build-release.sh 'rm -rf "$ROOT/dist"'
  expect_exact_line scripts/build-release.sh '"$ROOT/scripts/render-app-icon.swift" "$ICONSET"'
  expect_exact_line scripts/build-release.sh 'iconutil -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"'
  expect_exact_line scripts/build-release.sh '"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" --requirements "=$DESIGNATED_REQUIREMENT" "$APP"'
  expect_exact_line scripts/build-release.sh '"$CODESIGN" --verify --deep --strict --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$APP"'
fi

if [[ -f "$ROOT/scripts/install-local.sh" ]]; then
  expect_exact_line scripts/install-local.sh 'DEST_APP="$HOME/Applications/Codex 可.app"'
  expect_exact_line scripts/install-local.sh 'codex plugin marketplace add "$ROOT/dist/marketplace" --json'
  expect_exact_line scripts/install-local.sh 'codex plugin add codex-quick-ok --marketplace codex-quick-ok-local --json'
  expect_exact_line scripts/install-local.sh '"$LSREGISTER" -f "$DEST_APP"'
  expect_exact_line scripts/install-local.sh 'touch "$DEST_APP"'
  expect_exact_line scripts/install-local.sh 'killall Dock || true'
  expect_absent_text scripts/install-local.sh 'hooks\.json|config\.toml'
fi

if [[ -f "$ROOT/scripts/uninstall-local.sh" ]]; then
  expect_exact_line scripts/uninstall-local.sh 'APP="$HOME/Applications/Codex 可.app"'
  expect_exact_line scripts/uninstall-local.sh 'SUPPORT="$HOME/Library/Application Support/CodexQuickOK"'
  expect_exact_line scripts/uninstall-local.sh '  open -n -W "$APP" --args --unregister-login-item || true'
  expect_exact_line scripts/uninstall-local.sh 'rm -rf "$APP" "$SUPPORT"'
  rm_lines="$(grep -E '^[[:space:]]*rm([[:space:]]|$)' "$ROOT/scripts/uninstall-local.sh" || true)"
  [[ "$rm_lines" == 'rm -rf "$APP" "$SUPPORT"' ]] || fail 'uninstall may only delete the two owned paths'
  expect_absent_text scripts/uninstall-local.sh '^[[:space:]]*open -W "\$APP" --args --unregister-login-item'
  expect_absent_text scripts/uninstall-local.sh '\.codex/(config\.toml|hooks\.json)|tccutil|Accessibility'
fi

if [[ -f "$ROOT/README.md" ]]; then
  expected_headings=('# Codex 可' '## 安装' '## 使用' '## 安全边界' '## 卸载')
  previous=0
  for heading in "${expected_headings[@]}"; do
    line="$(grep -nFx -- "$heading" "$ROOT/README.md" | head -n 1 | cut -d: -f1 || true)"
    if [[ -z "$line" || "$line" -le "$previous" ]]; then
      fail "README heading missing or out of order: $heading"
      continue
    fi
    previous="$line"
  done
  expect_exact_line README.md 'zsh scripts/build-release.sh'
  expect_exact_line README.md 'zsh scripts/install-local.sh'
  expect_exact_line README.md 'zsh scripts/uninstall-local.sh'
fi

(( failures == 0 )) || exit 1
print 'Packaging static checks passed.'
