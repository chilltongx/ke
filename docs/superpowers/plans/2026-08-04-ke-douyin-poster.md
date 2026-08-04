# 「可」抖音宣传海报 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 生成一张可直接发布到抖音的 1080 × 1920「可」项目宣传海报。

**Architecture:** 使用内置 `image_gen` 生成无文字的低对比度背景纹理，再用 AppKit
确定性绘制“可”、全部文案和 Core Image 二维码。独立验证脚本检查 PNG 尺寸和二维码内容，
避免生成模型造成汉字、URL 或二维码错误。

**Tech Stack:** built-in `image_gen`、Swift、AppKit、Core Image、Vision、zsh

## Global Constraints

- 最终 PNG 固定为 1080 × 1920，9:16。
- 四边安全边距至少 72 px。
- 文案必须逐字匹配已批准规格，不得新增或改写。
- 二维码内容固定为 `https://github.com/chilltongx/ke`。
- 配色固定使用 `#1E1E1F`、`#111314`、`#F6F7F8`、`#55D6BE`、`#919996`。
- 生成模型不得绘制文字、二维码、第三方 Logo、水印或界面截图。
- 最终文件固定为 `marketing/ke-douyin-poster.png`。

## File Structure

- Create: `marketing/ke-poster-visual-philosophy.md` — 海报视觉哲学。
- Create: `marketing/assets/ke-poster-background.png` — 无文字背景纹理。
- Create: `scripts/render-douyin-poster.swift` — 确定性绘制海报。
- Create: `scripts/validate-douyin-poster.swift` — 检查尺寸并解码二维码。
- Create: `Tests/DouyinPosterTests.sh` — 回归测试入口。
- Create: `marketing/ke-douyin-poster.png` — 最终发布文件。

---

### Task 1: 视觉哲学与背景纹理

**Files:**
- Create: `marketing/ke-poster-visual-philosophy.md`
- Create: `marketing/assets/ke-poster-background.png`

**Interfaces:**
- Consumes: 已批准规格 `docs/superpowers/specs/2026-08-04-ke-douyin-poster-design.md`。
- Produces: 无文字竖版 PNG，供渲染器缩放为 1080 × 1920 背景输入。

- [ ] **Step 1: 写入视觉哲学**

创建 `marketing/ke-poster-visual-philosophy.md`，写入以下完整内容：

```markdown
# 「可」海报视觉哲学：信号印章

这张海报把一次点击理解成一道确定的信号。煤灰色空间不是普通黑底，而是一块安静、
有深度的技术场域；稀薄的同心信号环从画面上部扩散，暗示“光标在哪，就发到哪”的
即时响应，又不抢夺内容层级。

薄荷绿只承担信号角色。它出现在印章边缘、细刻度和极少量轨迹中，像 macOS 状态灯般
克制；高明度米白负责文字可读性，深灰负责结构。颜色越少，动作越清楚。

巨型“可”字被封在圆形印章中，既像一次确认，也像按键被触发后的回响。圆形位于画面
约三分之一高度，是唯一的强焦点；标题、说明、应用列表依次向下收束，让视线自然抵达
二维码和开源地址。

排版追求顶级编辑设计的秩序感：至少 72 像素安全边距、稳定基线、精准字距和大片留白。
信息不靠装饰堆叠，而靠尺度差、间距与对齐建立节奏，每一处空白都服务于阅读速度。

最终质感应像经过反复校准的印刷成品，而不是模板拼接。背景保留极轻微的纸面与信号
纹理，所有中文、URL 和二维码则由程序确定性绘制，确保克制的手工气质与工程精度同时成立。
```

- [ ] **Step 2: 使用内置 image_gen 生成背景**

使用以下完整提示词，生成一张竖版背景：

```text
Use case: ads-marketing
Asset type: 9:16 Douyin promotional poster background
Primary request: an abstract coal-black technical field for a minimalist macOS utility poster
Scene/backdrop: deep charcoal radial field with extremely subtle concentric signal rings and sparse cursor-path traces
Style/medium: museum-grade editorial graphic design, meticulous print texture, restrained and premium
Composition/framing: 1080x1920 vertical composition; visual energy centered around 31% canvas height; clear negative space at center and bottom for deterministic typography and QR overlay
Lighting/mood: quiet dark glow, precise, confident, technical
Color palette: #111314, #1E1E1F, faint #55D6BE accents only
Constraints: background only; no words; no letters; no numbers; no Chinese characters; no UI; no devices; no logos; no QR code; no watermark; no bright focal object; preserve at least 72px clean margins
Avoid: cyberpunk neon, busy particles, stock-photo look, fake interface panels, decorative clutter
```

将选中的生成结果保存为 `marketing/assets/ke-poster-background.png`。

- [ ] **Step 3: 检查背景**

使用 `view_image` 检查：无任何文字、二维码、Logo；中心和底部留白充足；薄荷色只作微弱信号。
不满足时只迭代一项：降低纹理对比度。

- [ ] **Step 4: 提交视觉资产**

```bash
git add marketing/ke-poster-visual-philosophy.md marketing/assets/ke-poster-background.png
git commit -m "feat(marketing): Add poster visual foundation"
```

### Task 2: 确定性海报渲染与验证

**Files:**
- Create: `scripts/render-douyin-poster.swift`
- Create: `scripts/validate-douyin-poster.swift`
- Create: `Tests/DouyinPosterTests.sh`

**Interfaces:**
- Consumes: `render-douyin-poster.swift <background.png> <output.png>`。
- Produces: 1080 × 1920 PNG；`validate-douyin-poster.swift <poster.png>` 成功时退出 0。

- [ ] **Step 1: 写失败测试**

创建 `Tests/DouyinPosterTests.sh`：

```zsh
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
```

- [ ] **Step 2: 运行测试并确认失败**

Run: `zsh Tests/DouyinPosterTests.sh`

Expected: FAIL，提示 `scripts/render-douyin-poster.swift` 不存在。

- [ ] **Step 3: 实现渲染器**

创建 `scripts/render-douyin-poster.swift`，写入以下完整实现：

```swift
#!/usr/bin/env swift
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

let canvas = NSSize(width: 1_080, height: 1_920)
let safeMargin: CGFloat = 72
let repositoryURL = "https://github.com/chilltongx/ke"

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("poster renderer: \(message)\n".utf8))
    exit(code)
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

func font(named name: String, size: CGFloat, weight: NSFont.Weight) -> NSFont {
    NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
}

func attributes(
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment,
    tracking: CGFloat = 0
) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    return [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: tracking,
    ]
}

func drawCenteredText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    rect: NSRect,
    tracking: CGFloat = 0
) {
    let attrs = attributes(font: font, color: color, alignment: .center, tracking: tracking)
    let size = (text as NSString).size(withAttributes: attrs)
    let verticalRect = NSRect(
        x: rect.minX,
        y: rect.midY - size.height / 2,
        width: rect.width,
        height: size.height + 4
    )
    (text as NSString).draw(in: verticalRect, withAttributes: attrs)
}

func drawLeftText(
    _ text: String,
    font: NSFont,
    color: NSColor,
    rect: NSRect,
    tracking: CGFloat = 0
) {
    (text as NSString).draw(
        in: rect,
        withAttributes: attributes(font: font, color: color, alignment: .left, tracking: tracking)
    )
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: render-douyin-poster.swift <background.png> <output.png>", code: 64)
}

let backgroundURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let background = NSImage(contentsOf: backgroundURL),
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: false,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
      ),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
else {
    fail("could not load background or allocate bitmap", code: 65)
}

bitmap.size = canvas
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
graphics.imageInterpolation = .high
let bounds = NSRect(origin: .zero, size: canvas)
color(0x111314).setFill()
bounds.fill()
background.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 0.72)

let mint = color(0x55D6BE)
let ivory = color(0xF6F7F8)
let muted = color(0x919996)
let coal = color(0x1E1E1F)

let ringStyles: [(diameter: CGFloat, alpha: CGFloat, width: CGFloat)] = [
    (720, 0.07, 1),
    (640, 0.12, 1),
]
for (diameter, alpha, width) in ringStyles {
    let ring = NSBezierPath(ovalIn: NSRect(
        x: canvas.width / 2 - diameter / 2,
        y: 1_325 - diameter / 2,
        width: diameter,
        height: diameter
    ))
    ring.lineWidth = width
    mint.withAlphaComponent(alpha).setStroke()
    ring.stroke()
}

drawCenteredText(
    "MACOS · OPEN SOURCE",
    font: NSFont.monospacedSystemFont(ofSize: 19, weight: .medium),
    color: muted,
    rect: NSRect(x: safeMargin, y: 1_775, width: canvas.width - safeMargin * 2, height: 42),
    tracking: 4
)

let sealRect = NSRect(x: 260, y: 1_045, width: 560, height: 560)
coal.withAlphaComponent(0.96).setFill()
NSBezierPath(ovalIn: sealRect).fill()
let sealBorder = NSBezierPath(ovalIn: sealRect.insetBy(dx: 4, dy: 4))
sealBorder.lineWidth = 2
mint.withAlphaComponent(0.82).setStroke()
sealBorder.stroke()

for angle in stride(from: CGFloat(0), to: 360, by: 30) {
    let radians = angle * .pi / 180
    let inner = NSPoint(x: 540 + cos(radians) * 290, y: 1_325 + sin(radians) * 290)
    let outer = NSPoint(x: 540 + cos(radians) * 302, y: 1_325 + sin(radians) * 302)
    let tick = NSBezierPath()
    tick.move(to: inner)
    tick.line(to: outer)
    tick.lineWidth = angle.truncatingRemainder(dividingBy: 90) == 0 ? 2 : 1
    mint.withAlphaComponent(0.52).setStroke()
    tick.stroke()
}

drawCenteredText(
    "可",
    font: font(named: "PingFangSC-Semibold", size: 296, weight: .semibold),
    color: ivory,
    rect: sealRect.offsetBy(dx: 0, dy: 12)
)
drawCenteredText(
    "一键，可。",
    font: font(named: "PingFangSC-Semibold", size: 68, weight: .semibold),
    color: ivory,
    rect: NSRect(x: safeMargin, y: 900, width: canvas.width - safeMargin * 2, height: 94)
)
drawCenteredText(
    "光标在哪，就发到哪",
    font: font(named: "PingFangSC-Regular", size: 34, weight: .regular),
    color: muted,
    rect: NSRect(x: safeMargin, y: 817, width: canvas.width - safeMargin * 2, height: 52)
)
drawCenteredText(
    "CODEX · VS CODE · 微信",
    font: NSFont.monospacedSystemFont(ofSize: 23, weight: .medium),
    color: mint,
    rect: NSRect(x: safeMargin, y: 691, width: canvas.width - safeMargin * 2, height: 40),
    tracking: 2
)

let divider = NSBezierPath()
divider.move(to: NSPoint(x: safeMargin, y: 585))
divider.line(to: NSPoint(x: canvas.width - safeMargin, y: 585))
divider.lineWidth = 1
muted.withAlphaComponent(0.3).setStroke()
divider.stroke()

drawLeftText(
    "扫码开源免费用",
    font: font(named: "PingFangSC-Medium", size: 31, weight: .medium),
    color: ivory,
    rect: NSRect(x: safeMargin, y: 210, width: 620, height: 48)
)
drawLeftText(
    "github.com/chilltongx/ke",
    font: NSFont.monospacedSystemFont(ofSize: 20, weight: .regular),
    color: muted,
    rect: NSRect(x: safeMargin, y: 148, width: 620, height: 36),
    tracking: 0.4
)

let qr = CIFilter.qrCodeGenerator()
qr.message = Data(repositoryURL.utf8)
qr.correctionLevel = "M"
guard let qrImage = qr.outputImage else {
    fail("could not generate QR code", code: 66)
}

let ciContext = CIContext(options: [.useSoftwareRenderer: false])
guard let qrCGImage = ciContext.createCGImage(qrImage, from: qrImage.extent) else {
    fail("could not render QR code", code: 66)
}

let modules = Int(qrImage.extent.width.rounded())
let quietModules = 4
let qrMaximum: CGFloat = 228
let moduleScale = max(1, Int(qrMaximum) / (modules + quietModules * 2))
let qrBox = CGFloat((modules + quietModules * 2) * moduleScale)
let qrOrigin = NSPoint(x: canvas.width - safeMargin - qrBox, y: 112)
let quietRect = NSRect(origin: qrOrigin, size: NSSize(width: qrBox, height: qrBox))
NSColor.white.setFill()
quietRect.fill()

let codeOrigin = NSPoint(
    x: qrOrigin.x + CGFloat(quietModules * moduleScale),
    y: qrOrigin.y + CGFloat(quietModules * moduleScale)
)
let codeSide = CGFloat(modules * moduleScale)
graphics.cgContext.interpolationQuality = .none
graphics.cgContext.draw(
    qrCGImage,
    in: CGRect(origin: codeOrigin, size: CGSize(width: codeSide, height: codeSide))
)

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fail("could not encode PNG", code: 67)
}

do {
    try FileManager.default.createDirectory(
        at: outputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try png.write(to: outputURL, options: .atomic)
} catch {
    fail("could not write output: \(error.localizedDescription)", code: 68)
}
```

- [ ] **Step 4: 实现验证器**

创建 `scripts/validate-douyin-poster.swift`，写入以下完整实现：

```swift
#!/usr/bin/env swift
import AppKit
import Foundation
import Vision

let expectedWidth = 1_080
let expectedHeight = 1_920
let expectedPayload = "https://github.com/chilltongx/ke"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("poster validation failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: validate-douyin-poster.swift <poster.png>")
}

let posterURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: posterURL),
      let bitmap = NSBitmapImageRep(data: data),
      let cgImage = bitmap.cgImage
else {
    fail("could not load PNG")
}

guard bitmap.pixelsWide == expectedWidth, bitmap.pixelsHigh == expectedHeight else {
    fail("expected \(expectedWidth)x\(expectedHeight), got \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
}

let request = VNDetectBarcodesRequest()
request.symbologies = [.qr]

do {
    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
} catch {
    fail("Vision error: \(error.localizedDescription)")
}

let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
guard payloads.contains(expectedPayload) else {
    fail("QR payload mismatch; detected \(payloads)")
}

print("Poster valid: \(expectedWidth)x\(expectedHeight), QR -> \(expectedPayload)")
```

- [ ] **Step 5: 运行测试并确认通过**

Run: `zsh Tests/DouyinPosterTests.sh`

Expected: `Douyin poster checks passed.`

- [ ] **Step 6: 提交渲染与验证工具**

```bash
git add scripts/render-douyin-poster.swift scripts/validate-douyin-poster.swift Tests/DouyinPosterTests.sh
git commit -m "feat(marketing): Add deterministic poster renderer"
```

### Task 3: 生成、检查并交付最终海报

**Files:**
- Create: `marketing/ke-douyin-poster.png`

**Interfaces:**
- Consumes: Task 1 背景、Task 2 渲染器。
- Produces: 可直接上传抖音的最终 PNG。

- [ ] **Step 1: 生成最终 PNG**

```bash
swift scripts/render-douyin-poster.swift \
  marketing/assets/ke-poster-background.png \
  marketing/ke-douyin-poster.png
```

- [ ] **Step 2: 自动验证**

```bash
swift scripts/validate-douyin-poster.swift marketing/ke-douyin-poster.png
zsh Tests/DouyinPosterTests.sh
```

Expected: 两条命令退出 0，二维码内容与尺寸准确。

- [ ] **Step 3: 视觉检查**

使用 `view_image` 原始分辨率检查：标题、副标题、应用列表、CTA、URL 和二维码互不重叠；
主视觉顺序为“可”印章、主标题、导流区；边缘无裁切；背景不干扰文字。

- [ ] **Step 4: 提交最终海报**

```bash
git add marketing/ke-douyin-poster.png
git commit -m "feat(marketing): Add Douyin launch poster"
```

- [ ] **Step 5: 交付**

在最终回复中直接展示 `marketing/ke-douyin-poster.png`，并给出可点击的绝对路径。
