#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$ROOT/dist/Codex 可.app"
DEST_APP="$HOME/Applications/Codex 可.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

test -d "$SOURCE_APP" || zsh "$ROOT/scripts/build-release.sh"
mkdir -p "$HOME/Applications"
rm -rf "$DEST_APP"
ditto "$SOURCE_APP" "$DEST_APP"
"$LSREGISTER" -f "$DEST_APP"
touch "$DEST_APP"

killall Dock || true
open "$DEST_APP"
print '请在系统设置中仅授予“Codex 可”辅助功能权限。'
print '以后点击 Dock 图标即可手动启动；右键退出后不会自动重启。'
