import AppKit
import Foundation
@testable import Trove

/// A fresh, empty directory under the system temporary directory, unique per call.
func makeTempDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TroveTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A store rooted in its own temporary directory, and the URL of its history file. Every file the
/// store writes (sidecars, images) stays under that root.
@MainActor
func makeTempStore() -> (ClipStore, URL) {
    let files = ClipFiles(root: makeTempDirectory())
    return (ClipStore(files: files), files.historyFile)
}

/// A solid-color RGBA bitmap of the given size.
@MainActor
func makeBitmap(width: Int, height: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemOrange.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// The same bitmap encoded as PNG.
@MainActor
func makePNG(width: Int, height: Int) -> Data {
    makeBitmap(width: width, height: height).representation(using: .png, properties: [:])!
}
