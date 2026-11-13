import AppKit
import Foundation
import Testing
@testable import Trove

@MainActor
struct ImageIngestTests {
    @Test func pngPayloadPassesThroughUntouched() {
        let original = makePNG(width: 40, height: 30)
        #expect(ImageIngest.pngData(from: PasteboardImagePayload(data: original, type: .png)) == original)
    }

    @Test func tiffPayloadIsConvertedToPNG() throws {
        let tiff = makeBitmap(width: 40, height: 30).tiffRepresentation!
        let converted = try #require(ImageIngest.pngData(from: PasteboardImagePayload(data: tiff, type: .tiff)))
        #expect(converted != tiff)
        let decoded = try #require(NSBitmapImageRep(data: converted))
        #expect(decoded.pixelsWide == 40)
        #expect(decoded.pixelsHigh == 30)
        // PNG magic bytes.
        #expect(converted.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
    }
}
