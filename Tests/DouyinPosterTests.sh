#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
OUTPUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUTPUT_DIR"' EXIT
POSTER="$OUTPUT_DIR/ke-douyin-poster.png"

swift "$ROOT/scripts/render-douyin-poster.swift" \
  "$ROOT/marketing/assets/ke-poster-background.png" \
  "$POSTER"
swift "$ROOT/scripts/validate-douyin-poster.swift" "$POSTER"

for copy in \
  'MACOS · OPEN SOURCE' \
  '一键，可。' \
  '光标在哪，就发到哪' \
  'CODEX · VS CODE · 微信' \
  '扫码开源免费用' \
  'github.com/chilltongx/ke'; do
  rg -F --quiet "$copy" "$ROOT/scripts/render-douyin-poster.swift"
done

print 'Douyin poster checks passed.'
