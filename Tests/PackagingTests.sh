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
  docs/manual-verification.md \
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
expect_executable Tests/BuildReleaseTests.sh

expect_exact_line .gitignore 'dist/'

if [[ -f "$ROOT/Resources/Info.plist" ]]; then
  bundle_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist" 2>/dev/null)"
  bundle_build_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$ROOT/Resources/Info.plist" 2>/dev/null)" == CodexQuickOKApp ]] || fail 'unexpected CFBundleExecutable'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist" 2>/dev/null)" == com.codexquickok.CodexQuickOK ]] || fail 'unexpected CFBundleIdentifier'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 'Codex 可' ]] || fail 'unexpected CFBundleName'
  [[ "$bundle_short_version" == 0.1.0 ]] || fail 'unexpected short version'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Resources/Info.plist" 2>/dev/null)" == AppIcon ]] || fail 'CFBundleIconFile must be AppIcon'
  [[ "$bundle_build_version" == 8 ]] || fail 'bundle version must be 8'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 14.0 ]] || fail 'unexpected minimum system version'
  if /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$ROOT/Resources/Info.plist" >/dev/null 2>&1; then
    fail 'LSUIElement must be absent so Dock reopen remains reachable'
  fi
  expect_exact_line docs/manual-verification.md "# Manual Verification — Build ${bundle_build_version}"
  expect_exact_line docs/manual-verification.md "| Bundle version | ${bundle_short_version} (${bundle_build_version}) | Yes，与 \`Info.plist\` 一致性检查 |"
fi

expect_exact_line Sources/CodexQuickOKApp/AppMain.swift '        app.setActivationPolicy(.regular)'

if [[ -f "$ROOT/Resources/PrivacyInfo.xcprivacy" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == false ]] || fail 'NSPrivacyTracking must be false'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == 'Array {'$'\n''}' ]] || fail 'collected data types must be empty'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' "$ROOT/Resources/PrivacyInfo.xcprivacy" 2>/dev/null)" == 'Array {'$'\n''}' ]] || fail 'accessed API types must be empty'
fi

if [[ -f "$ROOT/scripts/build-release.sh" ]]; then
  expect_exact_line scripts/build-release.sh '"$SWIFT" build --package-path "$ROOT" -c release'
  expect_exact_line scripts/build-release.sh 'STAGING_ROOT="$("$MKTEMP" -d "$DIST_DIR/.CodexQuickOK-build.XXXXXX")"'
  expect_exact_line scripts/build-release.sh '"$ICON_RENDERER" "$ICONSET"'
  expect_exact_line scripts/build-release.sh '"$ICONUTIL" -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'cp "$ICON_BUILD_DIR/AppIcon.icns" \'
  expect_exact_line scripts/build-release.sh '  "$APP/Contents/Resources/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"'
  expect_exact_line scripts/build-release.sh '"$CODESIGN" --force --timestamp=none --sign "$identity_sha1" --keychain "$LOGIN_KEYCHAIN" --requirements "=$DESIGNATED_REQUIREMENT" "$APP"'
  expect_exact_line scripts/build-release.sh '"$CODESIGN" --verify --deep --strict --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$APP"'
  expect_absent_text scripts/build-release.sh '^rm -rf "\$ROOT/dist"$'
fi

if [[ -f "$ROOT/scripts/install-local.sh" ]]; then
  expect_exact_line scripts/install-local.sh 'DEST_APP="$HOME/Applications/Codex 可.app"'
  expect_exact_line scripts/install-local.sh 'APP_PROCESS="CodexQuickOKApp"'
  expect_exact_line scripts/install-local.sh 'STOP_ATTEMPTS=50'
  expect_exact_line scripts/install-local.sh 'DEST_EXECUTABLE="$DEST_APP/Contents/MacOS/CodexQuickOKApp"'
  expect_exact_line scripts/install-local.sh '    [[ "$executable" == "$DEST_EXECUTABLE" ]] && print -r -- "$pid"'
  expect_exact_line scripts/install-local.sh '    "$KILL" -TERM "$pid"'
  expect_exact_line scripts/install-local.sh '  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do'
  expect_exact_line scripts/install-local.sh '      "$KILL" -0 "$pid" 2>/dev/null && still_running=true'
  expect_exact_line scripts/install-local.sh '    "$SLEEP" 0.1'
  expect_exact_line scripts/install-local.sh '  print -u2 -- "Codex 可未能在 5 秒内退出；安装已中止。"'
  expect_exact_line scripts/install-local.sh '  return 75'
  expect_exact_line scripts/install-local.sh 'stop_running_app'
  expect_exact_line scripts/install-local.sh 'verify_app "$SOURCE_APP"'
  expect_exact_line scripts/install-local.sh 'STAGING_ROOT="$("$MKTEMP" -d "$HOME/Applications/.CodexQuickOK.install.XXXXXX")"'
  expect_exact_line scripts/install-local.sh '"$DITTO" "$SOURCE_APP" "$STAGED_APP"'
  expect_exact_line scripts/install-local.sh 'verify_app "$STAGED_APP"'
  expect_exact_line scripts/install-local.sh '"$LSREGISTER" -f "$DEST_APP"'
  expect_exact_line scripts/install-local.sh '"$TOUCH" "$DEST_APP"'
  expect_exact_line scripts/install-local.sh '"$KILLALL" Dock || true'
  expect_absent_text scripts/install-local.sh 'killall "\$APP_PROCESS"|killall CodexQuickOKApp'
  expect_line_before scripts/install-local.sh \
    '  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do' \
    '  print -u2 -- "Codex 可未能在 5 秒内退出；安装已中止。"'
  expect_line_before scripts/install-local.sh 'verify_app "$SOURCE_APP"' 'stop_running_app'
  expect_line_before scripts/install-local.sh 'verify_app "$STAGED_APP"' 'stop_running_app'
fi

if [[ -f "$ROOT/scripts/uninstall-local.sh" ]]; then
  expect_exact_line scripts/uninstall-local.sh 'APP="$HOME/Applications/Codex 可.app"'
  expect_exact_line scripts/uninstall-local.sh 'SUPPORT="$HOME/Library/Application Support/CodexQuickOK"'
  expect_exact_line scripts/uninstall-local.sh \
    'codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true'
  expect_exact_line scripts/uninstall-local.sh \
    'codex plugin marketplace remove codex-quick-ok-local --json || true'
  expect_exact_line scripts/uninstall-local.sh '  "$OPEN" -n -W "$APP" --args --unregister-login-item'
  expect_exact_line scripts/uninstall-local.sh '"$RM" -rf "$APP" "$SUPPORT"'
  expect_absent_text scripts/uninstall-local.sh 'unregister-login-item.*\|\| true'
  expect_absent_text scripts/uninstall-local.sh '^[[:space:]]*open -W "\$APP" --args --unregister-login-item'
  expect_absent_text scripts/uninstall-local.sh '\.codex/(config\.toml|hooks\.json)|tccutil|Accessibility'
fi

expect_absent_text Package.swift 'CodexQuickOKHook'
expect_absent_text scripts/build-release.sh 'CodexQuickOKHook|dist/marketplace|PLUGIN='
expect_absent_text scripts/install-local.sh 'codex plugin|/hooks|登录项'
expect_absent_text README.md '/hooks|等待批准任务|登录项默认开启'

zsh "$ROOT/Tests/InstallLocalTests.sh" || fail 'install-local behavioral checks failed'
zsh "$ROOT/Tests/BuildReleaseTests.sh" || fail 'build-release behavioral checks failed'

if [[ -f "$ROOT/README.md" ]]; then
  expected_headings=(
    '# 可'
    '## macOS'
    '### 安装'
    '### 使用'
    '### 安全边界'
    '### 卸载'
    '## Windows 11 x64 测试版'
    '## 许可证'
  )
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
