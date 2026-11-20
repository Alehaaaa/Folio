// Convert Folio's existing macOS artwork into an iOS-native, edge-to-edge icon.
//
// macOS icons deliberately include transparent margins and a rounded square;
// using the .icns directly on iOS causes a second rounded mask and a dark
// border around the app icon. This script removes the macOS margins, retains
// the original white Folio glyph and orange gradient, and produces an opaque
// 1024x1024 square for the system to mask.
//
// Usage: cd app/iOS && swift make_app_icon.swift

import AppKit
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let sourceURL = root.deletingLastPathComponent()
    .appendingPathComponent("Support/Folio.icns")
let outputURL = root.appendingPathComponent(
    "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)
let dimension = 1024
let stride = dimension * 4
let space = CGColorSpace(name: CGColorSpace.sRGB)!

guard let icon = NSImage(contentsOf: sourceURL),
      let original = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Cannot open Folio's original macOS icon at \(sourceURL.path)")
}

func bitmap(draw: (CGContext) -> Void) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: dimension * stride)
    data.withUnsafeMutableBytes { rawBuffer in
        guard let context = CGContext(
            data: rawBuffer.baseAddress,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: stride,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                        CGBitmapInfo.byteOrder32Big.rawValue
        ) else { fatalError("Cannot create RGB bitmap") }
        context.interpolationQuality = .high
        draw(context)
    }
    return data
}

// Extract the same CGImage twice: original pixels calibrate the existing
// gradient, while the second bitmap scales the opaque orange artwork to fit
// the full iOS canvas without changing the Folio emblem.
let source = bitmap { $0.draw(original, in: CGRect(x: 0, y: 0, width: dimension, height: dimension)) }
let visibleSize = 824.0 // macOS artwork occupies original pixels ~100...924
let scale = Double(dimension) / visibleSize
let scaled = bitmap {
    $0.draw(original, in: CGRect(x: -100 * scale,
                                 y: -100 * scale,
                                 width: Double(dimension) * scale,
                                 height: Double(dimension) * scale))
}

func sourcePixel(_ x: Int, _ y: Int, _ channel: Int) -> Double {
    Double(source[(y * dimension + x) * 4 + channel])
}

// Folio's orange-to-coral background is a gentle two-dimensional gradient.
// Its four unoccluded background samples define the colors used to extend
// the gradient into the previously transparent macOS corners.
let upperLeft = (180, 180)
let upperRight = (850, 180)
let lowerLeft = (180, 850)
let lowerRight = (850, 850)

func extendedBackground(_ sx: Double, _ sy: Double, channel: Int) -> UInt8 {
    let u = (sx - Double(upperLeft.0)) / Double(upperRight.0 - upperLeft.0)
    let v = (sy - Double(upperLeft.1)) / Double(lowerLeft.1 - upperLeft.1)
    let upper = sourcePixel(upperLeft.0, upperLeft.1, channel) * (1 - u)
              + sourcePixel(upperRight.0, upperRight.1, channel) * u
    let lower = sourcePixel(lowerLeft.0, lowerLeft.1, channel) * (1 - u)
              + sourcePixel(lowerRight.0, lowerRight.1, channel) * u
    return UInt8(max(0, min(255, (upper * (1 - v) + lower * v).rounded())))
}

var result = scaled
for y in 0..<dimension {
    let sourceY = 100.0 + (Double(y) / Double(dimension - 1)) * visibleSize
    for x in 0..<dimension {
        let i = (y * dimension + x) * 4
        if scaled[i + 3] < 250 {
            // The original icon's outer rounded boundary is macOS-only.
            // Extending its own gradient prevents dark or translucent corners.
            let sourceX = 100.0 + (Double(x) / Double(dimension - 1)) * visibleSize
            for channel in 0..<3 {
                result[i + channel] = extendedBackground(sourceX, sourceY, channel: channel)
            }
        }
        result[i + 3] = 255 // App Store app icon artwork must be opaque.
    }
}

let imageData = Data(result)
let provider = CGDataProvider(data: imageData as CFData)!
guard let finalImage = CGImage(
    width: dimension,
    height: dimension,
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: stride,
    space: space,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        .union(.byteOrder32Big),
    provider: provider,
    decode: nil,
    shouldInterpolate: true,
    intent: .defaultIntent
), let png = NSBitmapImageRep(cgImage: finalImage).representation(using: .png, properties: [:]) else {
    fatalError("Cannot encode an iOS AppIcon PNG")
}

try png.write(to: outputURL, options: .atomic)
print("Generated iOS full-bleed icon from macOS Folio.icns: \(outputURL.path)")
