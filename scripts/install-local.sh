#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${CODEX_QUICK_OK_SOURCE_APP:-$ROOT/dist/Codex 可.app}"
DEST_APP="$HOME/Applications/Codex 可.app"
DEST_EXECUTABLE="$DEST_APP/Contents/MacOS/CodexQuickOKApp"
DEFAULT_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LSREGISTER="${CODEX_QUICK_OK_LSREGISTER:-$DEFAULT_LSREGISTER}"
SIGNING_IDENTITY_NAME="${CODEX_QUICK_OK_SIGNING_IDENTITY:-Codex Quick OK Local Signing}"
LOGIN_KEYCHAIN="${CODEX_QUICK_OK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SECURITY="${CODEX_QUICK_OK_SECURITY:-/usr/bin/security}"
CODESIGN="${CODEX_QUICK_OK_CODESIGN:-/usr/bin/codesign}"
PGREP="${CODEX_QUICK_OK_PGREP:-/usr/bin/pgrep}"
PS="${CODEX_QUICK_OK_PS:-/bin/ps}"
KILL="${CODEX_QUICK_OK_KILL:-/bin/kill}"
SLEEP="${CODEX_QUICK_OK_SLEEP:-/bin/sleep}"
DITTO="${CODEX_QUICK_OK_DITTO:-/usr/bin/ditto}"
MV="${CODEX_QUICK_OK_MV:-/bin/mv}"
RM="${CODEX_QUICK_OK_RM:-/bin/rm}"
MKDIR="${CODEX_QUICK_OK_MKDIR:-/bin/mkdir}"
MKTEMP="${CODEX_QUICK_OK_MKTEMP:-/usr/bin/mktemp}"
TOUCH="${CODEX_QUICK_OK_TOUCH:-/usr/bin/touch}"
OPEN="${CODEX_QUICK_OK_OPEN:-/usr/bin/open}"
KILLALL="${CODEX_QUICK_OK_KILLALL:-/usr/bin/killall}"
BUNDLE_IDENTIFIER="com.codexquickok.CodexQuickOK"
APP_PROCESS="CodexQuickOKApp"
STOP_ATTEMPTS=50
STAGING_ROOT=""
STAGED_APP=""
BACKUP_APP="$HOME/Applications/.Codex 可.app.backup.$$"
HAD_EXISTING=false
DEST_REPLACED=false
INSTALL_COMMITTED=false

rollback_destination() {
  if [[ "$DEST_REPLACED" == true ]]; then
    "$RM" -rf "$DEST_APP" || return 1
    if [[ "$HAD_EXISTING" == true && -e "$BACKUP_APP" ]]; then
      "$MV" "$BACKUP_APP" "$DEST_APP" || return 1
    fi
    DEST_REPLACED=false
  elif [[ "$HAD_EXISTING" == true \
      && -e "$BACKUP_APP" && ! -e "$DEST_APP" ]]; then
    "$MV" "$BACKUP_APP" "$DEST_APP" || return 1
  fi
}

cleanup() {
  if [[ "$INSTALL_COMMITTED" != true ]]; then
    rollback_destination || true
  fi
  [[ -z "$STAGING_ROOT" || ! -d "$STAGING_ROOT" ]] || "$RM" -rf "$STAGING_ROOT"
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
  if [[ "$common_name" == "$SIGNING_IDENTITY_NAME" && ${#sha1} -eq 40 \
      && "$sha1" != *[^[:xdigit:]]* && " ${identity_hashes[*]} " != *" $sha1 "* ]]; then
    identity_hashes+=("$sha1")
  fi
done <<< "$identity_output"

if (( ${#identity_hashes} != 1 )); then
  print -u2 -- "No unique valid code-signing identity named \"$SIGNING_IDENTITY_NAME\"."
  exit 78
fi
identity_sha1="${identity_hashes[1]}"
DESIGNATED_REQUIREMENT_EXPRESSION="identifier \"$BUNDLE_IDENTIFIER\" and certificate leaf = H\"$identity_sha1\""

verify_app() {
  "$CODESIGN" --verify --deep --strict \
    --test-requirement "=$DESIGNATED_REQUIREMENT_EXPRESSION" "$1"
}

owned_app_pids() {
  local pid executable output probe_status
  if output="$($PGREP -x "$APP_PROCESS" 2>/dev/null)"; then
    :
  else
    probe_status=$?
    [[ "$probe_status" -eq 1 ]] && return 0
    print -u2 -- 'Unable to inspect running Codex 可 processes; installation aborted.'
    return 74
  fi
  while IFS= read -r pid; do
    [[ "$pid" == <-> ]] || {
      print -u2 -- 'Unable to validate a running Codex 可 process identifier.'
      return 74
    }
    executable="$($PS -ww -p "$pid" -o comm=)" || {
      print -u2 -- "Unable to inspect running process $pid; installation aborted."
      return 74
    }
    executable="${executable##[[:space:]]#}"
    executable="${executable%%[[:space:]]#}"
    [[ "$executable" == "$DEST_EXECUTABLE" ]] && print -r -- "$pid"
  done <<< "$output"
  return 0
}

stop_running_app() {
  local -a pids
  local pid attempt still_running output
  output="$(owned_app_pids)" || return $?
  [[ -z "$output" ]] && return 0
  pids=("${(@f)output}")
  for pid in "${pids[@]}"; do
    "$KILL" -TERM "$pid"
  done
  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do
    still_running=false
    for pid in "${pids[@]}"; do
      "$KILL" -0 "$pid" 2>/dev/null && still_running=true
    done
    [[ "$still_running" == false ]] && return 0
    "$SLEEP" 0.1
  done
  print -u2 -- "Codex 可未能在 5 秒内退出；安装已中止。"
  return 75
}

test -d "$SOURCE_APP" || zsh "$ROOT/scripts/build-release.sh"
verify_app "$SOURCE_APP"
"$MKDIR" -p "$HOME/Applications"
STAGING_ROOT="$("$MKTEMP" -d "$HOME/Applications/.CodexQuickOK.install.XXXXXX")"
STAGED_APP="$STAGING_ROOT/Codex 可.app"
"$DITTO" "$SOURCE_APP" "$STAGED_APP"
verify_app "$STAGED_APP"
stop_running_app

if [[ -e "$DEST_APP" ]]; then
  "$MV" "$DEST_APP" "$BACKUP_APP"
  HAD_EXISTING=true
fi
if ! "$MV" "$STAGED_APP" "$DEST_APP"; then
  print -u2 -- 'Unable to swap the staged app into place; previous install restored.'
  exit 74
fi
DEST_REPLACED=true
verify_app "$DEST_APP"
"$LSREGISTER" -f "$DEST_APP"
"$TOUCH" "$DEST_APP"
"$KILLALL" Dock || true
if ! "$OPEN" -g "$DEST_APP"; then
  print -u2 -- 'Unable to open the replacement app; restoring the previous install.'
  if ! rollback_destination; then
    print -u2 -- 'Unable to restore the previous install after launch failure.'
    exit 74
  fi
  if [[ "$HAD_EXISTING" == true ]]; then
    "$LSREGISTER" -f "$DEST_APP" || true
    "$TOUCH" "$DEST_APP" || true
    "$OPEN" -g "$DEST_APP" || true
  fi
  exit 76
fi

INSTALL_COMMITTED=true
[[ "$HAD_EXISTING" != true ]] || "$RM" -rf "$BACKUP_APP"
print '请在系统设置中仅授予“Codex 可”辅助功能权限。'
print '以后点击 Dock 图标即可手动启动；右键退出后不会自动重启。'
