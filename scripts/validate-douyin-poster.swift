#!/usr/bin/env swift
import AppKit
import Foundation
import Vision

let expectedWidth = 1_080
let expectedHeight = 1_920
let expectedPayload = "https://github.com/chilltongx/ke"
let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("poster validation failed: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: validate-douyin-poster.swift <poster.png>")
}

let posterURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: posterURL) else {
    fail("could not load PNG")
}

guard data.starts(with: pngSignature) else {
    fail("expected PNG signature")
}

guard let bitmap = NSBitmapImageRep(data: data),
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
