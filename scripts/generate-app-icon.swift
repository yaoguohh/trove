#!/usr/bin/env swift

import AppKit
import Foundation

let outputURL = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "ClipDeck.icns")
let fileManager = FileManager.default
let workURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("ClipDeck.iconset-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workURL.appendingPathComponent("ClipDeck.iconset", isDirectory: true)

try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in specs {
    let image = renderIcon(size: size)
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw IconError.renderFailed
    }
    try png.write(to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    throw IconError.iconutilFailed(Int(process.terminationStatus))
}

try? fileManager.removeItem(at: workURL)

enum IconError: Error {
    case renderFailed
    case iconutilFailed(Int)
}

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    rect.fill()

    let scale = size / 1024
    let baseRect = rect.insetBy(dx: 74 * scale, dy: 74 * scale)
    let basePath = NSBezierPath(roundedRect: baseRect, xRadius: 220 * scale, yRadius: 220 * scale)
    let baseShadow = NSShadow()
    baseShadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    baseShadow.shadowBlurRadius = 30 * scale
    baseShadow.shadowOffset = NSSize(width: 0, height: -16 * scale)
    let baseGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.98, alpha: 1)
    ])
    NSGraphicsContext.saveGraphicsState()
    baseShadow.set()
    baseGradient?.draw(in: basePath, angle: -35)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.08).setStroke()
    basePath.lineWidth = 10 * scale
    basePath.stroke()

    drawCard(
        in: NSRect(x: 218 * scale, y: 246 * scale, width: 510 * scale, height: 520 * scale),
        rotation: -10,
        scale: scale,
        header: NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.55, alpha: 1),
        alpha: 0.70
    )
    drawCard(
        in: NSRect(x: 298 * scale, y: 206 * scale, width: 510 * scale, height: 560 * scale),
        rotation: 8,
        scale: scale,
        header: NSColor(calibratedRed: 0.54, green: 0.34, blue: 0.88, alpha: 1),
        alpha: 0.94
    )

    let clipRect = NSRect(x: 370 * scale, y: 626 * scale, width: 210 * scale, height: 96 * scale)
    let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: 44 * scale, yRadius: 44 * scale)
    NSColor.white.withAlphaComponent(0.92).setFill()
    clipPath.fill()
    NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.28, alpha: 1).setStroke()
    clipPath.lineWidth = 12 * scale
    clipPath.stroke()

    let dotPath = NSBezierPath(ovalIn: NSRect(x: 420 * scale, y: 660 * scale, width: 28 * scale, height: 28 * scale))
    NSColor(calibratedRed: 0.12, green: 0.72, blue: 0.55, alpha: 1).setFill()
    dotPath.fill()

    let shinePath = NSBezierPath()
    shinePath.move(to: NSPoint(x: 168 * scale, y: 820 * scale))
    shinePath.curve(
        to: NSPoint(x: 420 * scale, y: 928 * scale),
        controlPoint1: NSPoint(x: 230 * scale, y: 910 * scale),
        controlPoint2: NSPoint(x: 344 * scale, y: 956 * scale)
    )
    NSColor.black.withAlphaComponent(0.06).setStroke()
    shinePath.lineWidth = 24 * scale
    shinePath.stroke()

    return image
}

func drawCard(in rect: NSRect, rotation: CGFloat, scale: CGFloat, header: NSColor, alpha: CGFloat) {
    let center = NSPoint(x: rect.midX, y: rect.midY)
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: rotation)
    transform.translateX(by: -center.x, yBy: -center.y)

    NSGraphicsContext.saveGraphicsState()
    transform.concat()

    let cardPath = NSBezierPath(roundedRect: rect, xRadius: 52 * scale, yRadius: 52 * scale)
    let cardShadow = NSShadow()
    cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.18 * alpha)
    cardShadow.shadowBlurRadius = 28 * scale
    cardShadow.shadowOffset = NSSize(width: 0, height: -12 * scale)
    NSGraphicsContext.saveGraphicsState()
    cardShadow.set()
    NSColor.white.withAlphaComponent(alpha).setFill()
    cardPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.10).setStroke()
    cardPath.lineWidth = 6 * scale
    cardPath.stroke()

    let headerPath = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.maxY - 128 * scale, width: rect.width, height: 128 * scale), xRadius: 52 * scale, yRadius: 52 * scale)
    header.withAlphaComponent(alpha).setFill()
    headerPath.fill()

    NSColor(calibratedWhite: 0.12, alpha: 0.22 * alpha).setFill()
    for index in 0..<3 {
        let y = rect.maxY - (210 + CGFloat(index) * 92) * scale
        let lineRect = NSRect(x: rect.minX + 72 * scale, y: y, width: (310 - CGFloat(index) * 42) * scale, height: 28 * scale)
        NSBezierPath(roundedRect: lineRect, xRadius: 14 * scale, yRadius: 14 * scale).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
}
