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
    FileHandle.standardError.write(
        Data("usage: render-app-icon.swift <AppIcon.iconset>\n".utf8)
    )
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
let colorUnit: CGFloat = 1.0 / 255.0
let coal = NSColor(
    srgbRed: 31.0 * colorUnit,
    green: 34.0 * colorUnit,
    blue: 33.0 * colorUnit,
    alpha: 1
)
let ivory = NSColor(
    srgbRed: 242.0 * colorUnit,
    green: 239.0 * colorUnit,
    blue: 232.0 * colorUnit,
    alpha: 1
)
let ring = NSColor(
    srgbRed: 119.0 * colorUnit,
    green: 126.0 * colorUnit,
    blue: 122.0 * colorUnit,
    alpha: 1
)

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

    let canvas = CGFloat(pixels)
    bitmap.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

    let outerInset = canvas * 0.04
    let outerRect = NSRect(
        x: outerInset,
        y: outerInset,
        width: canvas - 2 * outerInset,
        height: canvas - 2 * outerInset
    )
    coal.setFill()
    NSBezierPath(
        roundedRect: outerRect,
        xRadius: canvas * 0.22,
        yRadius: canvas * 0.22
    ).fill()

    let ringInset = canvas * 0.145
    let ringRect = NSRect(
        x: ringInset,
        y: ringInset,
        width: canvas - 2 * ringInset,
        height: canvas - 2 * ringInset
    )
    ring.setStroke()
    let ringPath = NSBezierPath(ovalIn: ringRect)
    ringPath.lineWidth = max(1, canvas * 0.022)
    ringPath.stroke()

    let pointSize = canvas * 0.52
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
        x: (canvas - width) / 2,
        y: (canvas - ascent - descent) / 2 + descent
    )
    CTLineDraw(line, context)

    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename))
}
