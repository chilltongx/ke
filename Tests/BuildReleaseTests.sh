#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/scripts/build-release.sh"
WORK="$(mktemp -d)"
trap '/bin/rm -rf "$WORK"' EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

for line in \
  'DIST_DIR="${CODEX_QUICK_OK_DIST_DIR:-$ROOT/dist}"' \
  'BUILD_PRODUCT="${CODEX_QUICK_OK_BUILD_PRODUCT:-$ROOT/.build/release/CodexQuickOKApp}"' \
  'STAGING_ROOT="$("$MKTEMP" -d "$DIST_DIR/.CodexQuickOK-build.XXXXXX")"'; do
  grep -Fxq -- "$line" "$BUILD" || fail "build is missing atomic staging line: $line"
done

SHIMS="$WORK/shims"
mkdir -p "$SHIMS"
cat > "$SHIMS/command-shim" <<'SHIM'
#!/bin/zsh
name="${0:t}"
print -r -- "$name:$*" >> "$BUILD_TEST_LOG"
case "$name" in
  security)
    print '  1) CA25F15FECEACBC83936E31F3EAC0E994A447338 "Codex Quick OK Local Signing"'
    ;;
  swift) ;;
  renderer)
    /bin/mkdir -p "$1"
    ;;
  iconutil)
    output="${@[$(($@[(I)-o] + 1))]}"
    /bin/mkdir -p "${output:h}"
    print icon > "$output"
    ;;
  codesign)
    [[ "$BUILD_TEST_SCENARIO" == sign_failure && "$*" == *'--force'* ]] && exit 1
    exit 0
    ;;
  mv)
    if [[ "$BUILD_TEST_SCENARIO" == swap_failure && "$1" == *'.CodexQuickOK-build.'* ]]; then
      exit 1
    fi
    /bin/mv "$@"
    ;;
  *) exit 64 ;;
esac
SHIM
chmod +x "$SHIMS/command-shim"
for command in security swift renderer iconutil codesign mv; do
  ln -s command-shim "$SHIMS/$command"
done

run_scenario() {
  local scenario="$1"
  local scenario_root="$WORK/$scenario"
  local dist="$scenario_root/dist"
  local app="$dist/Codex 可.app"
  local product="$scenario_root/CodexQuickOKApp"
  local log="$scenario_root/events.log"
  mkdir -p "$app"
  print old > "$app/old-marker"
  print binary > "$product"
  : > "$log"

  set +e
  CODEX_QUICK_OK_DIST_DIR="$dist" \
  CODEX_QUICK_OK_BUILD_PRODUCT="$product" \
  CODEX_QUICK_OK_KEYCHAIN="$scenario_root/login.keychain-db" \
  CODEX_QUICK_OK_SECURITY="$SHIMS/security" \
  CODEX_QUICK_OK_CODESIGN="$SHIMS/codesign" \
  CODEX_QUICK_OK_SWIFT="$SHIMS/swift" \
  CODEX_QUICK_OK_ICON_RENDERER="$SHIMS/renderer" \
  CODEX_QUICK_OK_ICONUTIL="$SHIMS/iconutil" \
  CODEX_QUICK_OK_MV="$SHIMS/mv" \
  BUILD_TEST_SCENARIO="$scenario" \
  BUILD_TEST_LOG="$log" \
    zsh "$BUILD" >"$scenario_root/stdout" 2>"$scenario_root/stderr"
  typeset -g STATUS=$?
  set -e
  typeset -g APP="$app"
  typeset -g STDERR_FILE="$scenario_root/stderr"
  typeset -g STDOUT_FILE="$scenario_root/stdout"
  typeset -g EVENT_LOG="$log"
}

run_scenario sign_failure
[[ "$STATUS" -ne 0 ]] || fail 'signing failure unexpectedly succeeded'
[[ -f "$APP/old-marker" ]] || fail 'signing failure destroyed published app'

run_scenario swap_failure
[[ "$STATUS" -ne 0 ]] || fail 'publish swap failure unexpectedly succeeded'
[[ -f "$APP/old-marker" ]] || fail 'publish swap failure did not restore old app'

run_scenario success
if [[ "$STATUS" -ne 0 ]]; then
  tail -n 20 "$STDERR_FILE" >&2
  tail -n 20 "$STDOUT_FILE" >&2
  tail -n 40 "$EVENT_LOG" >&2
  fail "atomic build exited $STATUS"
fi
[[ -f "$APP/Contents/MacOS/CodexQuickOKApp" ]] || fail 'atomic build did not publish app'
[[ ! -f "$APP/old-marker" ]] || fail 'atomic build retained old app contents'

print 'Atomic release build checks passed.'
