#!/bin/zsh
set -euo pipefail

APP="$HOME/Applications/Codex 可.app"
SUPPORT="$HOME/Library/Application Support/CodexQuickOK"

# Clean up plugin registrations left by builds before manual mode.
codex plugin remove codex-quick-ok --marketplace codex-quick-ok-local --json || true
codex plugin marketplace remove codex-quick-ok-local --json || true

if [[ -d "$APP" ]]; then
  open -n -W "$APP" --args --unregister-login-item || true
fi

rm -rf "$APP" "$SUPPORT"
