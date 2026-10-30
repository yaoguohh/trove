import AppKit

/// Decoded-image caches keyed by file path, so SwiftUI bodies don't re-read and re-decode the same
/// PNG on every render (hover/selection animations re-evaluate bodies constantly).
///
/// Two tiers, because they have different lifetimes:
/// - `thumbnails` backs the cards. Thumbnails are ≤640px (see `ImageIngest`), so even a full strip
///   of image cards decodes to a few MB; this tier survives hide/show so re-summoning is instant.
/// - `fullImages` backs the peek bubble, the inspect window and drag-out. A single 4K screenshot
///   decodes to 33 MB, so this tier is purged whenever the panel hides — the footprint of a
///   background clipboard manager should not include every screenshot the user looked at.
///
/// Both have cost limits: without one an NSCache only evicts under system memory pressure, so
/// decoded bitmaps would accumulate unbounded. Each entry is charged its approximate RGBA size
/// (Apple: a 0-cost entry never counts against totalCostLimit).
@MainActor
enum ImageCache {
    private static let thumbnails: NSCache<NSString, NSImage> = makeCache(megabytes: 24)
    private static let fullImages: NSCache<NSString, NSImage> = makeCache(megabytes: 48)

    /// The card-sized rendition: the item's thumbnail, else (legacy items awaiting backfill, or a
    /// failed thumbnail) the original.
    static func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let url = item.thumbnailFileURL {
            return cached(url, in: thumbnails)
        }
        guard let url = item.imageFileURL else { return nil }
        return cached(url, in: fullImages)
    }

    /// The full-resolution image (peek, inspect window, drag-out).
    static func image(at url: URL) -> NSImage? {
        cached(url, in: fullImages)
    }

    /// Drop every full-size decode. Called when the panel hides; thumbnails stay.
    static func purgeFullImages() {
        fullImages.removeAllObjects()
    }

    private static func cached(_ url: URL, in cache: NSCache<NSString, NSImage>) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key, cost: estimatedCost(of: image))
        return image
    }

    private static func makeCache(megabytes: Int) -> NSCache<NSString, NSImage> {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = megabytes * 1024 * 1024
        return cache
    }

    private static func estimatedCost(of image: NSImage) -> Int {
        // Approximate the decoded RGBA footprint from the largest pixel representation.
        var maxPixels = 0
        for rep in image.representations {
            maxPixels = max(maxPixels, rep.pixelsWide * rep.pixelsHigh)
        }
        if maxPixels == 0 {
            maxPixels = max(0, Int(image.size.width * image.size.height))
        }
        return maxPixels * 4
    }
}
