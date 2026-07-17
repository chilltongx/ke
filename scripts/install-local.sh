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

codex plugin marketplace add "$ROOT/dist/marketplace" --json
codex plugin add codex-quick-ok --marketplace codex-quick-ok-local --json

killall Dock || true
open "$DEST_APP"
print '下一步 1：在系统设置中仅授予“Codex 可”辅助功能权限。'
print '下一步 2：在 Codex /hooks 中审查并信任 codex-quick-ok。'
