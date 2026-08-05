#!/usr/bin/env swift

import AppKit
import Foundation

// One-time source for the committed App.ico. The release build consumes App.ico
// directly and does not require Swift, AppKit, downloaded fonts, or image tools.

let frameSizes = [16, 24, 32, 48, 64, 128, 256]
let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App.ico")

func pngFrame(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "KeIcon", code: 1)
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        NSGraphicsContext.restoreGraphicsState()
        throw NSError(domain: "KeIcon", code: 2)
    }

    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    canvas.fill()

    let inset = max(0.75, CGFloat(size) / 128.0)
    let circle = NSBezierPath(ovalIn: canvas.insetBy(dx: inset, dy: inset))
    NSColor(calibratedRed: 30 / 255, green: 30 / 255, blue: 31 / 255, alpha: 1).setFill()
    circle.fill()

    circle.lineWidth = max(1, CGFloat(size) / 32.0)
    NSColor(calibratedRed: 85 / 255, green: 214 / 255, blue: 190 / 255, alpha: 1).setStroke()
    circle.stroke()

    let font = NSFont.systemFont(ofSize: CGFloat(size) * 0.56, weight: .semibold)
    let text = NSAttributedString(
        string: "可",
        attributes: [
            .font: font,
            .foregroundColor: NSColor(
                calibratedRed: 246 / 255,
                green: 247 / 255,
                blue: 248 / 255,
                alpha: 1
            )
        ]
    )
    let textSize = text.size()
    text.draw(at: NSPoint(
        x: (CGFloat(size) - textSize.width) / 2,
        y: (CGFloat(size) - textSize.height) / 2 + CGFloat(size) * 0.015
    ))

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "KeIcon", code: 3)
    }

    return data
}

func appendUInt16(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

func appendUInt32(_ value: UInt32, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
}

let frames = try frameSizes.map(pngFrame)
var icon = Data()
appendUInt16(0, to: &icon)
appendUInt16(1, to: &icon)
appendUInt16(UInt16(frames.count), to: &icon)

var offset = UInt32(6 + frames.count * 16)
for (index, frame) in frames.enumerated() {
    let size = frameSizes[index]
    icon.append(size == 256 ? 0 : UInt8(size))
    icon.append(size == 256 ? 0 : UInt8(size))
    icon.append(0)
    icon.append(0)
    appendUInt16(1, to: &icon)
    appendUInt16(32, to: &icon)
    appendUInt32(UInt32(frame.count), to: &icon)
    appendUInt32(offset, to: &icon)
    offset += UInt32(frame.count)
}

for frame in frames {
    icon.append(frame)
}

try icon.write(to: outputURL, options: .atomic)
