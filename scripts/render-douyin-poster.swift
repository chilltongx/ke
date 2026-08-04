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
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
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
