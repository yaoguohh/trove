import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image clips on disk: the stored PNG and its card-sized thumbnail. ImageIO only — thread-safe, no
/// AppKit — so every function here can run on a background task.
enum ImageFiles {
    /// Card thumbnails are rendered at ≤ ~300×140pt (600×280px); this covers that with headroom.
    static let thumbnailMaxPixelSize = 640

    enum ThumbnailResult: Equatable {
        /// A downsampled PNG was produced.
        case generated(Data)
        /// The original is already within `thumbnailMaxPixelSize`; use it as its own thumbnail.
        case notNeeded
        /// The data could not be decoded.
        case failed
    }

    struct StoredFiles: Sendable, Equatable {
        let imageFileName: String
        let thumbnailFileName: String?
    }

    static func imageFileName(for id: UUID) -> String { "\(id.uuidString).png" }
    static func thumbnailFileName(for id: UUID) -> String { "\(id.uuidString).thumb.png" }

    /// A PNG no larger than `maxPixelSize` on its long edge, produced by ImageIO's downsampling
    /// decoder (never materialises the full bitmap when the source is much larger).
    static func thumbnail(from png: Data, maxPixelSize: Int = thumbnailMaxPixelSize) -> ThumbnailResult {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return .failed }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) <= maxPixelSize {
            return .notNeeded
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let data = encodePNG(thumbnail) else { return .failed }
        return .generated(data)
    }

    /// Writes the image (and its thumbnail, when one is needed) atomically into `directory`.
    static func writeFiles(id: UUID, png: Data, directory: URL) throws -> StoredFiles {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imageName = imageFileName(for: id)
        try png.write(to: directory.appendingPathComponent(imageName), options: .atomic)

        let thumbnailName: String?
        switch thumbnail(from: png) {
        case .generated(let data):
            let name = thumbnailFileName(for: id)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
            thumbnailName = name
        case .notNeeded:
            thumbnailName = imageName
        case .failed:
            thumbnailName = nil
        }
        return StoredFiles(imageFileName: imageName, thumbnailFileName: thumbnailName)
    }

    /// Encodes a decoded image as PNG (ImageIO, safe off the main thread).
    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
