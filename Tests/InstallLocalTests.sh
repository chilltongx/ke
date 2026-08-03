#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-local.sh"
UNINSTALLER="$ROOT/scripts/uninstall-local.sh"
TMP_ROOT="$(mktemp -d)"
SHIM_DIR="$TMP_ROOT/shims"
IDENTITY_SHA1="CA25F15FECEACBC83936E31F3EAC0E994A447338"

cleanup() { /bin/rm -rf "$TMP_ROOT" }
trap cleanup EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

expect_event() {
  grep -Fq -- "$2" "$1" || fail "missing event '$2' in $1"
}

expect_no_event() {
  grep -Fq -- "$2" "$1" && fail "unexpected event '$2' in $1"
  return 0
}

expect_event_count() {
  local actual
  actual="$(grep -Fc -- "$2" "$1" || true)"
  [[ "$actual" -eq "$3" ]] \
    || fail "expected $3 occurrences of '$2' in $1, got $actual"
}

mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/command-shim" <<'SHIM'
#!/bin/zsh
set -u
name="${0:t}"
log="$INSTALL_TEST_LOG"
print -r -- "$name:$*" >> "$log"

case "$name" in
  security)
    print '  1) CA25F15FECEACBC83936E31F3EAC0E994A447338 "Codex Quick OK Local Signing"'
    ;;
  codesign)
    if [[ "$INSTALL_TEST_SCENARIO" == invalid_source && "$*" == *"$INSTALL_TEST_SOURCE" ]]; then
      exit 1
    fi
    ;;
  pgrep)
    case "$INSTALL_TEST_SCENARIO" in
      owned_and_unowned|owned_stuck) print '101'; print '202' ;;
      *) exit 1 ;;
    esac
    ;;
  ps)
    [[ "$*" == *"101"* ]] && print -r -- "$INSTALL_TEST_OWNED_EXECUTABLE" || \
      print -r -- '/tmp/unowned/CodexQuickOKApp'
    ;;
  kill)
    if [[ "${1:-}" == -0 ]]; then
      [[ "$INSTALL_TEST_SCENARIO" == owned_stuck ]] && exit 0
      count=0
      [[ -f "$INSTALL_TEST_KILL_COUNT" ]] && count="$(<"$INSTALL_TEST_KILL_COUNT")"
      count=$((count + 1))
      print -r -- "$count" > "$INSTALL_TEST_KILL_COUNT"
      (( count < 2 )) && exit 0 || exit 1
    fi
    ;;
  sleep) ;;
  ditto)
    [[ "$INSTALL_TEST_SCENARIO" == copy_failure ]] && exit 1
    /bin/mkdir -p "$2"
    print -r -- new > "$2/new-marker"
    ;;
  mv)
    if [[ "$INSTALL_TEST_SCENARIO" == swap_failure && "$1" == *'.install.'* ]]; then
      exit 1
    fi
    /bin/mv "$@"
    ;;
  rm) /bin/rm "$@" ;;
  mkdir) /bin/mkdir "$@" ;;
  mktemp) /usr/bin/mktemp "$@" ;;
  touch) /usr/bin/touch "$@" ;;
  open)
    if [[ "$INSTALL_TEST_SCENARIO" == open_failure ]]; then
      count=0
      [[ -f "$INSTALL_TEST_OPEN_COUNT" ]] && count="$(<"$INSTALL_TEST_OPEN_COUNT")"
      count=$((count + 1))
      print -r -- "$count" > "$INSTALL_TEST_OPEN_COUNT"
      (( count == 1 )) && exit 1
    fi
    ;;
  lsregister|killall) ;;
  codex) ;;
  *) exit 64 ;;
esac
SHIM
chmod +x "$SHIM_DIR/command-shim"
for command in security codesign pgrep ps kill sleep ditto mv rm mkdir mktemp touch \
  lsregister open killall codex; do
  ln -s command-shim "$SHIM_DIR/$command"
done

run_install() {
  local scenario="$1"
  local scenario_root="$TMP_ROOT/$scenario"
  local home="$scenario_root/home"
  local source="$scenario_root/source/Codex 可.app"
  local dest="$home/Applications/Codex 可.app"
  local log="$scenario_root/events.log"
  mkdir -p "$source" "$dest"
  print -r -- old > "$dest/old-marker"
  : > "$log"
  : > "$scenario_root/kill-count"
  : > "$scenario_root/open-count"

  set +e
  HOME="$home" \
  PATH="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  CODEX_QUICK_OK_SOURCE_APP="$source" \
  CODEX_QUICK_OK_KEYCHAIN="$scenario_root/login.keychain-db" \
  CODEX_QUICK_OK_SECURITY="$SHIM_DIR/security" \
  CODEX_QUICK_OK_CODESIGN="$SHIM_DIR/codesign" \
  CODEX_QUICK_OK_LSREGISTER="$SHIM_DIR/lsregister" \
  CODEX_QUICK_OK_PGREP="$SHIM_DIR/pgrep" \
  CODEX_QUICK_OK_PS="$SHIM_DIR/ps" \
  CODEX_QUICK_OK_KILL="$SHIM_DIR/kill" \
  CODEX_QUICK_OK_SLEEP="$SHIM_DIR/sleep" \
  CODEX_QUICK_OK_DITTO="$SHIM_DIR/ditto" \
  CODEX_QUICK_OK_MV="$SHIM_DIR/mv" \
  CODEX_QUICK_OK_RM="$SHIM_DIR/rm" \
  CODEX_QUICK_OK_MKDIR="$SHIM_DIR/mkdir" \
  CODEX_QUICK_OK_MKTEMP="$SHIM_DIR/mktemp" \
  CODEX_QUICK_OK_TOUCH="$SHIM_DIR/touch" \
  CODEX_QUICK_OK_OPEN="$SHIM_DIR/open" \
  CODEX_QUICK_OK_KILLALL="$SHIM_DIR/killall" \
  INSTALL_TEST_SCENARIO="$scenario" \
  INSTALL_TEST_LOG="$log" \
  INSTALL_TEST_SOURCE="$source" \
  INSTALL_TEST_OWNED_EXECUTABLE="$dest/Contents/MacOS/CodexQuickOKApp" \
  INSTALL_TEST_KILL_COUNT="$scenario_root/kill-count" \
  INSTALL_TEST_OPEN_COUNT="$scenario_root/open-count" \
    zsh "$INSTALLER" >"$scenario_root/stdout" 2>"$scenario_root/stderr"
  typeset -g SCENARIO_STATUS=$?
  set -e

  typeset -g SCENARIO_HOME="$home"
  typeset -g SCENARIO_SOURCE="$source"
  typeset -g SCENARIO_DEST="$dest"
  typeset -g SCENARIO_LOG="$log"
  typeset -g SCENARIO_STDERR="$scenario_root/stderr"
}

run_install invalid_source
[[ "$SCENARIO_STATUS" -ne 0 ]] || fail 'invalid source signature must fail'
[[ -f "$SCENARIO_DEST/old-marker" ]] || fail 'invalid source replaced working install'
expect_no_event "$SCENARIO_LOG" 'pgrep:'
expect_no_event "$SCENARIO_LOG" 'ditto:'

run_install owned_and_unowned
if [[ "$SCENARIO_STATUS" -ne 0 ]]; then
  tail -n 30 "$SCENARIO_STDERR" >&2
  tail -n 60 "$SCENARIO_LOG" >&2
  fail "owned-process install exited $SCENARIO_STATUS"
fi
expect_event "$SCENARIO_LOG" 'kill:-TERM 101'
expect_no_event "$SCENARIO_LOG" 'kill:-TERM 202'
expect_event "$SCENARIO_LOG" 'kill:-0 101'
expect_no_event "$SCENARIO_LOG" 'kill:-0 202'
expect_event "$SCENARIO_LOG" "codesign:--verify --deep --strict --test-requirement =identifier \"com.codexquickok.CodexQuickOK\" and certificate leaf = H\"$IDENTITY_SHA1\" $SCENARIO_SOURCE"
[[ -f "$SCENARIO_DEST/new-marker" ]] || fail 'successful install did not publish staged app'
[[ ! -f "$SCENARIO_DEST/old-marker" ]] || fail 'successful install kept old app contents'

run_install no_process
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "no-process install exited $SCENARIO_STATUS"
expect_no_event "$SCENARIO_LOG" 'kill:'
[[ -f "$SCENARIO_DEST/new-marker" ]] || fail 'no-process install did not publish staged app'

run_install owned_stuck
[[ "$SCENARIO_STATUS" -eq 75 ]] || fail "stuck owned process must exit 75, got $SCENARIO_STATUS"
[[ -f "$SCENARIO_DEST/old-marker" ]] || fail 'stuck process replaced working install'
expect_no_event "$SCENARIO_LOG" "mv:$SCENARIO_DEST"

run_install copy_failure
[[ "$SCENARIO_STATUS" -ne 0 ]] || fail 'copy failure must fail install'
[[ -f "$SCENARIO_DEST/old-marker" ]] || fail 'copy failure removed working install'

run_install swap_failure
[[ "$SCENARIO_STATUS" -ne 0 ]] || fail 'swap failure must fail install'
[[ -f "$SCENARIO_DEST/old-marker" ]] || fail 'swap failure did not restore working install'
[[ ! -f "$SCENARIO_DEST/new-marker" ]] || fail 'swap failure left staged app at destination'

run_install open_failure
[[ "$SCENARIO_STATUS" -ne 0 ]] || fail 'open failure must fail install'
[[ -f "$SCENARIO_DEST/old-marker" ]] || fail 'open failure did not restore working install'
[[ ! -f "$SCENARIO_DEST/new-marker" ]] || fail 'open failure kept replacement app'
expect_event_count "$SCENARIO_LOG" "lsregister:-f $SCENARIO_DEST" 2
expect_event_count "$SCENARIO_LOG" "open:$SCENARIO_DEST" 2

run_uninstall() {
  local scenario="$1"
  local scenario_root="$TMP_ROOT/uninstall-$scenario"
  local home="$scenario_root/home"
  local app="$home/Applications/Codex 可.app"
  local support="$home/Library/Application Support/CodexQuickOK"
  local log="$scenario_root/events.log"
  mkdir -p "$app" "$support"
  : > "$log"
  set +e
  HOME="$home" \
  PATH="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  CODEX_QUICK_OK_OPEN="$SHIM_DIR/open" \
  CODEX_QUICK_OK_RM="$SHIM_DIR/rm" \
  INSTALL_TEST_SCENARIO="$scenario" \
  INSTALL_TEST_LOG="$log" \
  INSTALL_TEST_SOURCE='' \
  INSTALL_TEST_OWNED_EXECUTABLE='' \
  INSTALL_TEST_KILL_COUNT="$scenario_root/kill-count" \
  INSTALL_TEST_OPEN_COUNT="$scenario_root/open-count" \
    zsh "$UNINSTALLER" >"$scenario_root/stdout" 2>"$scenario_root/stderr"
  typeset -g UNINSTALL_STATUS=$?
  set -e
  typeset -g UNINSTALL_APP="$app"
  typeset -g UNINSTALL_SUPPORT="$support"
}

# The open shim represents the helper result. Force one helper failure without
# touching an installed app outside the isolated HOME.
/bin/rm "$SHIM_DIR/open"
cat > "$SHIM_DIR/open" <<'SHIM'
#!/bin/zsh
print -r -- "open:$*" >> "$INSTALL_TEST_LOG"
[[ "$INSTALL_TEST_SCENARIO" == helper_failure ]] && exit 1
exit 0
SHIM
chmod +x "$SHIM_DIR/open"

run_uninstall helper_failure
[[ "$UNINSTALL_STATUS" -ne 0 ]] || fail 'uninstall swallowed login helper failure'
[[ -d "$UNINSTALL_APP" && -d "$UNINSTALL_SUPPORT" ]] \
  || fail 'uninstall deleted files after login helper failure'

run_uninstall helper_success
[[ "$UNINSTALL_STATUS" -eq 0 ]] || fail "successful uninstall exited $UNINSTALL_STATUS"
[[ ! -e "$UNINSTALL_APP" && ! -e "$UNINSTALL_SUPPORT" ]] \
  || fail 'successful uninstall kept owned files'

print 'Install/uninstall behavioral checks passed.'
