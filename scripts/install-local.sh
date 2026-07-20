#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${CODEX_QUICK_OK_SOURCE_APP:-$ROOT/dist/Codex 可.app}"
DEST_APP="$HOME/Applications/Codex 可.app"
DEFAULT_LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
LSREGISTER="${CODEX_QUICK_OK_LSREGISTER:-$DEFAULT_LSREGISTER}"
APP_PROCESS="CodexQuickOKApp"
STOP_ATTEMPTS=50

stop_running_app() {
  pgrep -x "$APP_PROCESS" >/dev/null || return 0
  killall "$APP_PROCESS"
  local attempt
  for (( attempt = 0; attempt < STOP_ATTEMPTS; attempt++ )); do
    sleep 0.1
    pgrep -x "$APP_PROCESS" >/dev/null || return 0
  done
  print -u2 -- "Codex 可未能在 5 秒内退出；安装已中止。"
  return 75
}

test -d "$SOURCE_APP" || zsh "$ROOT/scripts/build-release.sh"
mkdir -p "$HOME/Applications"
stop_running_app
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
"$LSREGISTER" -f "$DEST_APP"
touch "$DEST_APP"

killall Dock || true
open "$DEST_APP"
print '请在系统设置中仅授予“Codex 可”辅助功能权限。'
print '以后点击 Dock 图标即可手动启动；右键退出后不会自动重启。'
