import Foundation
import AppKit
import Testing
@testable import Trove

@MainActor
struct ImageIngestTests {
    private func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
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

    private func png(width: Int, height: Int) -> Data {
        bitmap(width: width, height: height).representation(using: .png, properties: [:])!
    }

    @Test func largeImageGetsADownsampledThumbnail() throws {
        guard case .generated(let thumbnail) = ImageIngest.thumbnail(from: png(width: 1600, height: 900)) else {
            Issue.record("expected a generated thumbnail")
            return
        }
        let decoded = try #require(NSBitmapImageRep(data: thumbnail))
        #expect(decoded.pixelsWide == ImageIngest.thumbnailMaxPixelSize)
        #expect(decoded.pixelsHigh == 360)
    }

    @Test func smallImageNeedsNoThumbnail() {
        #expect(ImageIngest.thumbnail(from: png(width: 300, height: 200)) == .notNeeded)
        #expect(ImageIngest.thumbnail(from: png(width: 640, height: 640)) == .notNeeded)
    }

    @Test func undecodableBytesFail() {
        #expect(ImageIngest.thumbnail(from: Data([0x01, 0x02, 0x03])) == .failed)
    }

    @Test func pngPayloadPassesThroughUntouched() {
        let original = png(width: 40, height: 30)
        #expect(ImageIngest.pngData(from: PasteboardImagePayload(data: original, type: .png)) == original)
    }

    @Test func tiffPayloadIsConvertedToPNG() throws {
        let tiff = bitmap(width: 40, height: 30).tiffRepresentation!
        let converted = try #require(ImageIngest.pngData(from: PasteboardImagePayload(data: tiff, type: .tiff)))
        #expect(converted != tiff)
        let decoded = try #require(NSBitmapImageRep(data: converted))
        #expect(decoded.pixelsWide == 40)
        #expect(decoded.pixelsHigh == 30)
        // PNG magic bytes.
        #expect(converted.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func writeFilesStoresImageAndThumbnail() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let files = try ImageIngest.writeFiles(id: id, png: png(width: 1400, height: 700), directory: directory)
        #expect(files.imageFileName == "\(id.uuidString).png")
        #expect(files.thumbnailFileName == "\(id.uuidString).thumb.png")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(files.imageFileName).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(files.thumbnailFileName!).path))

        // A small original is its own thumbnail: one file, two references.
        let small = try ImageIngest.writeFiles(id: UUID(), png: png(width: 200, height: 100), directory: directory)
        #expect(small.thumbnailFileName == small.imageFileName)
    }
}
