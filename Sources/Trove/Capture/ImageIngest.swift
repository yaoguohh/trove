import Foundation
import ImageIO

/// A bitmap lifted off the pasteboard: the raw bytes plus which type they were read as.
struct PasteboardImagePayload: Sendable, Equatable {
    let data: Data
    let type: PasteboardIngest.ImageType
}

/// Turning a pasteboard bitmap into the PNG that `ImageFiles` stores. Runs on a background task;
/// the monitor never encodes on the main thread.
enum ImageIngest {
    /// Ceiling on a single pasteboard bitmap we are willing to store (CopyQ caps per-MIME reads too).
    static let maxImageBytes = 64 * 1024 * 1024

    /// PNG passes through verbatim (what the source app produced — no decode, no re-encode).
    /// Anything else is decoded once and encoded to PNG.
    static func pngData(from payload: PasteboardImagePayload) -> Data? {
        if payload.type == .png { return payload.data }
        guard let source = CGImageSourceCreateWithData(payload.data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ImageFiles.encodePNG(image)
    }
}
