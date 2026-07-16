# Codex 可 App Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the question-mark Dock tile with a deterministic coal-gray macOS app icon containing one accurate “可” glyph.

**Architecture:** A standalone Swift/AppKit renderer produces every required PNG in an iconset from one palette and layout definition. The release packager compiles that iconset to `AppIcon.icns`, copies it into the bundle, declares it in `Info.plist`, and refreshes Launch Services and Dock after installation.

**Tech Stack:** Swift 6, AppKit, CoreText, zsh, `iconutil`, `plutil`, `codesign`, Launch Services, SwiftPM.

## Global Constraints

- The icon is a deep coal-gray rounded square with one warm ivory “可” glyph and one restrained gray ring.
- Render “可” with PingFang SC Semibold or the semibold system-font fallback; do not use a generative image model.
- Generate all ten standard macOS iconset PNG names from 16 px through 1024 px.
- Keep the minimum supported OS at macOS 14.0 and add no third-party dependencies.
- Preserve installed plugin state, Hook configuration, Accessibility permission, login item, and session data.
- Never delete or rebuild unrelated Dock entries; refresh only Launch Services metadata and the Dock process.

---

### Task 1: Deterministic App Icon Renderer

**Files:**
- Create: `Tests/AppIconTests.sh`
- Create: `scripts/render-app-icon.swift`

**Interfaces:**
- Consumes: one output-directory argument containing the destination `AppIcon.iconset` path.
- Produces: ten PNGs with standard macOS iconset filenames and exact pixel dimensions.

- [ ] **Step 1: Write the failing renderer acceptance test**

Create `Tests/AppIconTests.sh` with executable mode:

```zsh
#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RENDERER="$ROOT/scripts/render-app-icon.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
ICNS="$WORK/AppIcon.icns"

test -x "$RENDERER"
rg -F 'let glyph = "可"' "$RENDERER" >/dev/null
rg -F 'PingFangSC-Semibold' "$RENDERER" >/dev/null

"$RENDERER" "$ICONSET"

while read -r name pixels; do
  file="$ICONSET/$name"
  test -f "$file"
  width="$(sips -g pixelWidth "$file" | awk '/pixelWidth/ { print $2 }')"
  height="$(sips -g pixelHeight "$file" | awk '/pixelHeight/ { print $2 }')"
  [[ "$width" == "$pixels" && "$height" == "$pixels" ]]
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

iconutil -c icns "$ICONSET" -o "$ICNS"
test -s "$ICNS"
print 'App icon renderer checks passed.'
```

- [ ] **Step 2: Run the renderer test and verify RED**

Run:

```bash
chmod +x Tests/AppIconTests.sh
zsh Tests/AppIconTests.sh
```

Expected: FAIL because `scripts/render-app-icon.swift` does not exist or is not executable.

- [ ] **Step 3: Implement the deterministic renderer**

Create `scripts/render-app-icon.swift` with executable mode:

```swift
#!/usr/bin/env swift
import AppKit
import CoreText
import Foundation

struct Variant {
    let filename: String
    let pixels: Int
}

let variants = [
    Variant(filename: "icon_16x16.png", pixels: 16),
    Variant(filename: "icon_16x16@2x.png", pixels: 32),
    Variant(filename: "icon_32x32.png", pixels: 32),
    Variant(filename: "icon_32x32@2x.png", pixels: 64),
    Variant(filename: "icon_128x128.png", pixels: 128),
    Variant(filename: "icon_128x128@2x.png", pixels: 256),
    Variant(filename: "icon_256x256.png", pixels: 256),
    Variant(filename: "icon_256x256@2x.png", pixels: 512),
    Variant(filename: "icon_512x512.png", pixels: 512),
    Variant(filename: "icon_512x512@2x.png", pixels: 1024),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-app-icon.swift <AppIcon.iconset>\n".utf8))
    exit(64)
}

let outputDirectory = URL(
    fileURLWithPath: CommandLine.arguments[1],
    isDirectory: true
)
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let glyph = "可"
let coal = NSColor(sRGBRed: 31 / 255, green: 34 / 255, blue: 33 / 255, alpha: 1)
let ivory = NSColor(sRGBRed: 242 / 255, green: 239 / 255, blue: 232 / 255, alpha: 1)
let ring = NSColor(sRGBRed: 119 / 255, green: 126 / 255, blue: 122 / 255, alpha: 1)

for variant in variants {
    let pixels = variant.pixels
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

    let outerInset = CGFloat(pixels) * 0.04
    let outerRect = NSRect(
        x: outerInset,
        y: outerInset,
        width: CGFloat(pixels) - 2 * outerInset,
        height: CGFloat(pixels) - 2 * outerInset
    )
    coal.setFill()
    NSBezierPath(
        roundedRect: outerRect,
        xRadius: CGFloat(pixels) * 0.22,
        yRadius: CGFloat(pixels) * 0.22
    ).fill()

    let ringInset = CGFloat(pixels) * 0.145
    let ringRect = NSRect(
        x: ringInset,
        y: ringInset,
        width: CGFloat(pixels) - 2 * ringInset,
        height: CGFloat(pixels) - 2 * ringInset
    )
    ring.setStroke()
    let ringPath = NSBezierPath(ovalIn: ringRect)
    ringPath.lineWidth = max(1, CGFloat(pixels) * 0.022)
    ringPath.stroke()

    let pointSize = CGFloat(pixels) * 0.52
    let font = NSFont(name: "PingFangSC-Semibold", size: pointSize)
        ?? NSFont.systemFont(ofSize: pointSize, weight: .semibold)
    let attributed = NSAttributedString(
        string: glyph,
        attributes: [
            .font: font,
            .foregroundColor: ivory,
        ]
    )
    let line = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    )
    let context = graphics.cgContext
    context.textPosition = CGPoint(
        x: (CGFloat(pixels) - width) / 2,
        y: (CGFloat(pixels) - ascent - descent) / 2 + descent
    )
    CTLineDraw(line, context)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename))
}
```

- [ ] **Step 4: Run the renderer test and visually inspect the 1024 px source**

Run:

```bash
chmod +x scripts/render-app-icon.swift
zsh Tests/AppIconTests.sh
rm -rf .build/app-icon-preview
scripts/render-app-icon.swift .build/app-icon-preview/AppIcon.iconset
```

Expected: `App icon renderer checks passed.` Then inspect `.build/app-icon-preview/AppIcon.iconset/icon_512x512@2x.png` with the image viewer and confirm one accurate “可”, coal background, ivory glyph, one gray ring, no clipping, and balanced optical centering.

- [ ] **Step 5: Commit the renderer**

```bash
git add Tests/AppIconTests.sh scripts/render-app-icon.swift
git commit -m "feat(icon): Render Codex Quick OK app icon"
```

---

### Task 2: Bundle, Install, and Refresh the Dock Icon

**Files:**
- Modify: `Resources/Info.plist`
- Modify: `scripts/build-release.sh`
- Modify: `scripts/install-local.sh`
- Modify: `Tests/PackagingTests.sh`
- Modify: `docs/manual-verification.md`

**Interfaces:**
- Consumes: `scripts/render-app-icon.swift <AppIcon.iconset>` from Task 1.
- Produces: `dist/Codex 可.app/Contents/Resources/AppIcon.icns` and an installed Dock tile that resolves the declared bundle icon.

- [ ] **Step 1: Add failing packaging assertions**

Extend `Tests/PackagingTests.sh` with these exact checks:

```zsh
expect_file scripts/render-app-icon.swift
expect_executable scripts/render-app-icon.swift
expect_executable Tests/AppIconTests.sh

if [[ -f "$ROOT/Resources/Info.plist" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$ROOT/Resources/Info.plist" 2>/dev/null)" == AppIcon ]] || fail 'CFBundleIconFile must be AppIcon'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/Resources/Info.plist" 2>/dev/null)" == 2 ]] || fail 'bundle version must be 2'
fi

if [[ -f "$ROOT/scripts/build-release.sh" ]]; then
  expect_exact_line scripts/build-release.sh '"$ROOT/scripts/render-app-icon.swift" "$ICONSET"'
  expect_exact_line scripts/build-release.sh 'iconutil -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"'
  expect_exact_line scripts/build-release.sh 'cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"'
fi

if [[ -f "$ROOT/scripts/install-local.sh" ]]; then
  expect_exact_line scripts/install-local.sh '"$LSREGISTER" -f "$DEST_APP"'
  expect_exact_line scripts/install-local.sh 'touch "$DEST_APP"'
  expect_exact_line scripts/install-local.sh 'killall Dock || true'
fi
```

- [ ] **Step 2: Run packaging checks and verify RED**

Run:

```bash
zsh Tests/PackagingTests.sh
```

Expected: FAIL because `CFBundleIconFile`, bundle version 2, icon build commands, and Dock refresh commands are absent.

- [ ] **Step 3: Declare the icon and increment the bundle build**

Add these entries to `Resources/Info.plist`:

```xml
<key>CFBundleIconFile</key>
<string>AppIcon</string>
```

Change:

```xml
<key>CFBundleVersion</key><string>1</string>
```

to:

```xml
<key>CFBundleVersion</key><string>2</string>
```

- [ ] **Step 4: Generate and package `AppIcon.icns` during every release build**

Insert this block in `scripts/build-release.sh` after the Swift release build and before signing:

```zsh
ICON_BUILD_DIR="$ROOT/.build/codex-quick-ok-app-icon"
ICONSET="$ICON_BUILD_DIR/AppIcon.iconset"
rm -rf "$ICON_BUILD_DIR"
mkdir -p "$ICON_BUILD_DIR"
"$ROOT/scripts/render-app-icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ICON_BUILD_DIR/AppIcon.icns"
```

After copying `PrivacyInfo.xcprivacy`, add:

```zsh
cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
```

Immediately before signing, add:

```zsh
test -s "$APP/Contents/Resources/AppIcon.icns"
```

- [ ] **Step 5: Refresh Launch Services and Dock without editing Dock entries**

Add this declaration near the path declarations in `scripts/install-local.sh`:

```zsh
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
```

After `ditto "$SOURCE_APP" "$DEST_APP"`, add:

```zsh
"$LSREGISTER" -f "$DEST_APP"
touch "$DEST_APP"
```

Immediately before `open "$DEST_APP"`, add:

```zsh
killall Dock || true
```

- [ ] **Step 6: Run focused tests, full tests, and release validation**

Run:

```bash
zsh Tests/AppIconTests.sh
zsh Tests/PackagingTests.sh
swift test
zsh scripts/build-release.sh
plutil -lint 'dist/Codex 可.app/Contents/Info.plist'
test -s 'dist/Codex 可.app/Contents/Resources/AppIcon.icns'
codesign --verify --deep --strict 'dist/Codex 可.app'
git diff --check
```

Expected: both shell test suites pass, all Swift tests pass, the icon exists in the signed bundle, plist validation passes, signature verification passes, and `git diff --check` prints nothing.

- [ ] **Step 7: Replace the installed app and verify Dock resolution**

Run:

```bash
pkill -TERM -x CodexQuickOKApp || true
zsh scripts/install-local.sh
/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$HOME/Applications/Codex 可.app/Contents/Info.plist"
test -s "$HOME/Applications/Codex 可.app/Contents/Resources/AppIcon.icns"
defaults read com.apple.dock persistent-apps | rg 'Codex%20%E5%8F%AF\.app'
```

Expected: `CFBundleIconFile` prints `AppIcon`, the installed ICNS is non-empty, the existing Dock item still points to `Codex 可.app`, and the Dock tile displays the designed “可” icon instead of a question mark. Clicking the tile launches the companion.

- [ ] **Step 8: Record icon verification evidence**

Append this section to `docs/manual-verification.md` with the actual result and date:

```markdown
## Dock icon regression

- [ ] Installed bundle declares `CFBundleIconFile = AppIcon`.
- [ ] Installed bundle contains a non-empty `Contents/Resources/AppIcon.icns`.
- [ ] Dock shows the coal-gray “可” icon instead of a question mark.
- [ ] Clicking the Dock tile launches `Codex 可`.
```

- [ ] **Step 9: Commit packaging integration**

```bash
git add Resources/Info.plist scripts/build-release.sh scripts/install-local.sh Tests/PackagingTests.sh docs/manual-verification.md
git commit -m "fix(icon): Package and refresh the app icon"
```
