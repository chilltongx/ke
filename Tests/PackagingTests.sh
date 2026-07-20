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

expect_line_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line="$(grep -nFx -- "$first" "$ROOT/$file" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nFx -- "$second" "$ROOT/$file" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    fail "$file must place '$first' before '$second'"
  fi
}

for file in \
  Resources/Info.plist \
  Resources/PrivacyInfo.xcprivacy \
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
expect_executable Tests/InstallLocalTests.sh

expect_exact_line .gitignore 'dist/'

if [[ -f "$ROOT/Resources/Info.plist" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT/Resources/Info.plist" 2>/dev/null)" == CodexQuickOKApp ]] || fail 'unexpected CFBundleExecutable'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist" 2>/dev/null)" == com.codexquickok.CodexQuickOK ]] || fail 'unexpected CFBundleIdentifier'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 'Codex 可' ]] || fail 'unexpected CFBundleName'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 0.1.0 ]] || fail 'unexpected short version'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Resources/Info.plist" 2>/dev/null)" == AppIcon ]] || fail 'CFBundleIconFile must be AppIcon'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 4 ]] || fail 'bundle version must be 4'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 14.0 ]] || fail 'unexpected minimum system version'
  if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$ROOT/Resources/Info.plist" >/dev/null 2>&1; then
    fail 'LSUIElement must be absent so Dock reopen remains reachable'
  fi
fi

expect_exact_line Sources/CodexQuickOKApp/AppMain.swift '        app.setActivationPolicy(.regular)'

if [[ -f "$ROOT/Resources/PrivacyInfo.xcprivacy" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == false ]] || fail 'NSPrivacyTracking must be false'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == 'Array {'$'\n''}' ]] || fail 'collected data types must be empty'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == 'Array {'$'\n''}' ]] || fail 'accessed API types must be empty'
fi

if [[ -f "$ROOT/scripts/build-release.sh" ]]; then
  expect_exact_line scripts/build-release.sh 'swift build --package-path "$ROOT" -c release'
  expect_exact_line scripts/build-release.sh 'rm -rf "$ROOT/dist"'
  expect_exact_line scripts/build-release.sh '"$ROOT/scripts/render-app-icon.swift" "$ICONSET"'
  expect_exact_line scripts/build-release.sh 'iconutil -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'cp "$ICON_BUILD_DIR/AppIcon.icns" \'
  expect_exact_line scripts/build-release.sh '  "$APP/Contents/Resources/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"'
  expect_exact_line scripts/build-release.sh '"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" --requirements "=$DESIGNATED_REQUIREMENT" "$APP"'
  expect_exact_line scripts/build-release.sh '"$CODESIGN" --verify --deep --strict --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$APP"'
fi

if [[ -f "$ROOT/scripts/install-local.sh" ]]; then
  expect_exact_line scripts/install-local.sh 'DEST_APP="$HOME/Applications/Codex 可.app"'
  expect_exact_line scripts/install-local.sh 'APP_PROCESS="CodexQuickOKApp"'
  expect_exact_line scripts/install-local.sh 'STOP_ATTEMPTS=50'
  expect_exact_line scripts/install-local.sh '  killall "$APP_PROCESS"'
  expect_exact_line scripts/install-local.sh '  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do'
  expect_exact_line scripts/install-local.sh '    pgrep -x "$APP_PROCESS" >/dev/null || return 0'
  expect_exact_line scripts/install-local.sh '    sleep 0.1'
  expect_exact_line scripts/install-local.sh '  print -u2 -- "Codex 可未能在 5 秒内退出；安装已中止。"'
  expect_exact_line scripts/install-local.sh '  return 75'
  expect_exact_line scripts/install-local.sh 'stop_running_app'
  expect_exact_line scripts/install-local.sh '"$LSREGISTER" -f "$DEST_APP"'
  expect_exact_line scripts/install-local.sh 'touch "$DEST_APP"'
  expect_exact_line scripts/install-local.sh 'killall Dock || true'
  expect_absent_text scripts/install-local.sh 'killall "\$APP_PROCESS".*\|\| true'
  expect_line_before scripts/install-local.sh '  killall "$APP_PROCESS"' \
    '  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do'
  expect_line_before scripts/install-local.sh \
    '  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do' \
    '  print -u2 -- "Codex 可未能在 5 秒内退出；安装已中止。"'
  expect_line_before scripts/install-local.sh 'stop_running_app' 'rm -rf "$DEST_APP"'
  expect_line_before scripts/install-local.sh 'rm -rf "$DEST_APP"' 'open "$DEST_APP"'
fi

if [[ -f "$ROOT/scripts/uninstall-local.sh" ]]; then
  expect_exact_line scripts/uninstall-local.sh 'APP="$HOME/Applications/Codex 可.app"'
  expect_exact_line scripts/uninstall-local.sh 'SUPPORT="$HOME/Library/Application Support/CodexQuickOK"'
  expect_exact_line scripts/uninstall-local.sh \
    'codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true'
  expect_exact_line scripts/uninstall-local.sh \
    'codex plugin marketplace remove codex-quick-ok-local --json || true'
  expect_exact_line scripts/uninstall-local.sh '  open -n -W "$APP" --args --unregister-login-item || true'
  expect_exact_line scripts/uninstall-local.sh 'rm -rf "$APP" "$SUPPORT"'
  rm_lines="$(grep -E '^[[:space:]]*rm([[:space:]]|$)' "$ROOT/scripts/uninstall-local.sh" || true)"
  [[ "$rm_lines" == 'rm -rf "$APP" "$SUPPORT"' ]] || fail 'uninstall may only delete the two owned paths'
  expect_absent_text scripts/uninstall-local.sh '^[[:space:]]*open -W "\$APP" --args --unregister-login-item'
  expect_absent_text scripts/uninstall-local.sh '\.codex/(config\.toml|hooks\.json)|tccutil|Accessibility'
fi

expect_absent_text Package.swift 'CodexQuickOKHook'
expect_absent_text scripts/build-release.sh 'CodexQuickOKHook|dist/marketplace|PLUGIN='
expect_absent_text scripts/install-local.sh 'codex plugin|/hooks|登录项'
expect_absent_text README.md '/hooks|等待批准任务|登录项默认开启'

zsh "$ROOT/Tests/InstallLocalTests.sh" || fail 'install-local behavioral checks failed'

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
