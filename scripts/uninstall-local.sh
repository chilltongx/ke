#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Codex 可.app"
SUPPORT="$HOME/Library/Application Support/CodexQuickOK"

codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true
codex plugin marketplace remove codex-quick-ok-local --json || true

if [[ -d "$APP" ]]; then
  open -W "$APP" --args --unregister-login-item || true
fi

rm -rf "$APP" "$SUPPORT"
