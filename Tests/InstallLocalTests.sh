#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="$ROOT/scripts/install-local.sh"
TMP_ROOT="$(mktemp -d)"
SHIM_DIR="$TMP_ROOT/shims"

cleanup() {
  /bin/rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

fail() {
  print -u2 -- "FAIL: $1"
  exit 1
}

require_exact_line() {
  local line="$1"
  grep -Fxq -- "$line" "$INSTALLER" || fail "installer is missing testable command override: $line"
}

event_count() {
  local log="$1"
  local pattern="$2"
  grep -cF -- "$pattern" "$log" || true
}

expect_event() {
  local log="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$log" || fail "missing event '$pattern' in $log"
}

expect_no_event() {
  local log="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$log"; then
    fail "unexpected event '$pattern' in $log"
  fi
}

expect_event_before() {
  local log="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line="$(grep -nF -- "$first" "$log" | head -n 1 | cut -d: -f1 || true)"
  second_line="$(grep -nF -- "$second" "$log" | head -n 1 | cut -d: -f1 || true)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    fail "expected '$first' before '$second' in $log"
  fi
}

require_exact_line 'SOURCE_APP="${CODEX_QUICK_OK_SOURCE_APP:-$ROOT/dist/Codex 可.app}"'
require_exact_line 'LSREGISTER="${CODEX_QUICK_OK_LSREGISTER:-$DEFAULT_LSREGISTER}"'

mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/command-shim" <<'SHIM'
#!/bin/zsh

command_name="${0:t}"
log="$INSTALL_TEST_LOG"

case "$command_name" in
  pgrep)
    count=0
    [[ -f "$INSTALL_TEST_PGREP_COUNT" ]] && count="$(<"$INSTALL_TEST_PGREP_COUNT")"
    count=$((count + 1))
    print -r -- "$count" > "$INSTALL_TEST_PGREP_COUNT"
    print -r -- "pgrep:$count:$*" >> "$log"
    case "$INSTALL_TEST_SCENARIO" in
      no_process) exit 1 ;;
      term_succeeds) (( count < 3 )) && exit 0 || exit 1 ;;
      stuck) exit 0 ;;
      *) exit 64 ;;
    esac
    ;;
  killall)
    print -r -- "killall:$*" >> "$log"
    ;;
  sleep)
    print -r -- "sleep:$*" >> "$log"
    ;;
  rm)
    print -r -- "rm:$*" >> "$log"
    /bin/rm "$@"
    ;;
  ditto)
    print -r -- "ditto:$*" >> "$log"
    /bin/mkdir -p "$2"
    ;;
  lsregister)
    print -r -- "lsregister:$*" >> "$log"
    ;;
  open)
    print -r -- "open:$*" >> "$log"
    ;;
  *) exit 64 ;;
esac
SHIM
chmod +x "$SHIM_DIR/command-shim"
for command in pgrep killall sleep rm ditto open lsregister; do
  ln -s command-shim "$SHIM_DIR/$command"
done

run_scenario() {
  local scenario="$1"
  local scenario_root="$TMP_ROOT/$scenario"
  local home="$scenario_root/home"
  local source="$scenario_root/source/Codex 可.app"
  local log="$scenario_root/events.log"
  local stdout="$scenario_root/stdout.log"
  local stderr="$scenario_root/stderr.log"
  local count="$scenario_root/pgrep-count"

  mkdir -p "$home" "$source"
  : > "$log"
  print -r -- 0 > "$count"

  set +e
  HOME="$home" \
  PATH="$SHIM_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
  CODEX_QUICK_OK_SOURCE_APP="$source" \
  CODEX_QUICK_OK_LSREGISTER="$SHIM_DIR/lsregister" \
  INSTALL_TEST_SCENARIO="$scenario" \
  INSTALL_TEST_LOG="$log" \
  INSTALL_TEST_PGREP_COUNT="$count" \
    zsh "$INSTALLER" >"$stdout" 2>"$stderr"
  local exit_code=$?
  set -e

  typeset -g SCENARIO_ROOT="$scenario_root"
  typeset -g SCENARIO_HOME="$home"
  typeset -g SCENARIO_SOURCE="$source"
  typeset -g SCENARIO_LOG="$log"
  typeset -g SCENARIO_STDERR="$stderr"
  typeset -g SCENARIO_COUNT="$count"
  typeset -g SCENARIO_STATUS="$exit_code"
}

run_scenario no_process
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "no-process install exited $SCENARIO_STATUS"
[[ "$(<"$SCENARIO_COUNT")" == 1 ]] || fail "no-process install must probe exactly once"
expect_no_event "$SCENARIO_LOG" 'killall:CodexQuickOKApp'
expect_no_event "$SCENARIO_LOG" 'sleep:'
expect_event "$SCENARIO_LOG" "rm:-rf $SCENARIO_HOME/Applications/Codex 可.app"
expect_event "$SCENARIO_LOG" "ditto:$SCENARIO_SOURCE $SCENARIO_HOME/Applications/Codex 可.app"
expect_event "$SCENARIO_LOG" "lsregister:-f $SCENARIO_HOME/Applications/Codex 可.app"
expect_event "$SCENARIO_LOG" "open:$SCENARIO_HOME/Applications/Codex 可.app"

run_scenario term_succeeds
[[ "$SCENARIO_STATUS" -eq 0 ]] || fail "terminating install exited $SCENARIO_STATUS"
[[ "$(<"$SCENARIO_COUNT")" == 3 ]] || fail "terminating install must stop after third probe"
[[ "$(event_count "$SCENARIO_LOG" 'sleep:0.1')" == 2 ]] || fail "terminating install must wait twice"
expect_event_before "$SCENARIO_LOG" 'killall:CodexQuickOKApp' 'sleep:0.1'
expect_event_before "$SCENARIO_LOG" 'pgrep:3:-x CodexQuickOKApp' "rm:-rf $SCENARIO_HOME/Applications/Codex 可.app"
expect_event_before "$SCENARIO_LOG" "rm:-rf $SCENARIO_HOME/Applications/Codex 可.app" "ditto:$SCENARIO_SOURCE"
expect_event_before "$SCENARIO_LOG" "ditto:$SCENARIO_SOURCE" 'lsregister:-f'
expect_event_before "$SCENARIO_LOG" 'lsregister:-f' "open:$SCENARIO_HOME/Applications/Codex 可.app"

run_scenario stuck
[[ "$SCENARIO_STATUS" -eq 75 ]] || fail "stuck install must exit 75, got $SCENARIO_STATUS"
[[ "$(<"$SCENARIO_COUNT")" == 51 ]] || fail "stuck install must perform one initial and 50 bounded probes"
[[ "$(event_count "$SCENARIO_LOG" 'sleep:0.1')" == 50 ]] || fail "stuck install must perform 50 bounded waits"
grep -Fq -- 'Codex 可未能在 5 秒内退出；安装已中止。' "$SCENARIO_STDERR" \
  || fail 'stuck install must explain timeout'
expect_no_event "$SCENARIO_LOG" 'rm:'
expect_no_event "$SCENARIO_LOG" 'ditto:'
expect_no_event "$SCENARIO_LOG" 'lsregister:'
expect_no_event "$SCENARIO_LOG" 'open:'
expect_no_event "$SCENARIO_LOG" 'killall:Dock'

print 'Install-local behavioral checks passed.'
