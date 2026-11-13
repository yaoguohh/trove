import AppKit
import Foundation
import Testing
@testable import Trove

@MainActor
struct ImageFilesTests {
    @Test func largeImageGetsADownsampledThumbnail() throws {
        guard case .generated(let thumbnail) = ImageFiles.thumbnail(from: makePNG(width: 1600, height: 900)) else {
            Issue.record("expected a generated thumbnail")
            return
        }
        let decoded = try #require(NSBitmapImageRep(data: thumbnail))
        #expect(decoded.pixelsWide == ImageFiles.thumbnailMaxPixelSize)
        #expect(decoded.pixelsHigh == 360)
    }

    @Test func smallImageNeedsNoThumbnail() {
        #expect(ImageFiles.thumbnail(from: makePNG(width: 300, height: 200)) == .notNeeded)
        #expect(ImageFiles.thumbnail(from: makePNG(width: 640, height: 640)) == .notNeeded)
    }

    @Test func undecodableBytesFail() {
        #expect(ImageFiles.thumbnail(from: Data([0x01, 0x02, 0x03])) == .failed)
    }

    @Test func writeFilesStoresImageAndThumbnail() throws {
        let directory = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = UUID()
        let files = try ImageFiles.writeFiles(id: id, png: makePNG(width: 1400, height: 700), directory: directory)
        #expect(files.imageFileName == "\(id.uuidString).png")
        #expect(files.thumbnailFileName == "\(id.uuidString).thumb.png")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(files.imageFileName).path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(files.thumbnailFileName!).path))

        // A small original is its own thumbnail: one file, two references.
        let small = try ImageFiles.writeFiles(id: UUID(), png: makePNG(width: 200, height: 100), directory: directory)
        #expect(small.thumbnailFileName == small.imageFileName)
    }
}
