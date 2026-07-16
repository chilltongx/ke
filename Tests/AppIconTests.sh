#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$ROOT/scripts/render-app-icon.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
SECOND_ICONSET="$WORK/Second.iconset"
ICNS="$WORK/AppIcon.icns"

test -x "$RENDERER"
rg -F 'let glyph = "可"' "$RENDERER" >/dev/null
rg -F 'PingFangSC-Semibold' "$RENDERER" >/dev/null

"$RENDERER" "$ICONSET"
"$RENDERER" "$SECOND_ICONSET"

while read -r name pixels; do
  file="$ICONSET/$name"
  test -f "$file"
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')"
  [[ "$width" == "$pixels" && "$height" == "$pixels" ]]
  cmp -s "$file" "$SECOND_ICONSET/$name"
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

[[ "$(find "$ICONSET" -type f -name '*.png' | wc -l | tr -d ' ')" == "10" ]]

iconutil -c icns "$ICONSET" -o "$ICNS"
test -s "$ICNS"
print 'App icon renderer checks passed.'
