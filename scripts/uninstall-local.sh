#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Codex 可.app"
SUPPORT="$HOME/Library/Application Support/CodexQuickOK"
OPEN="${CODEX_QUICK_OK_OPEN:-/usr/bin/open}"
RM="${CODEX_QUICK_OK_RM:-/bin/rm}"

# Clean up plugin registrations left by builds before manual mode.
codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true
codex plugin marketplace remove codex-quick-ok-local --json || true

if [[ -d "$APP" ]]; then
  "$OPEN" -n -W "$APP" --args --unregister-login-item
fi

"$RM" -rf "$APP" "$SUPPORT"
