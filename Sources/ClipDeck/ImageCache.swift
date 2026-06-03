import AppKit

/// Caches decoded images by file path so SwiftUI bodies don't re-read and re-decode
/// the same PNG from disk on every render (hover/selection animations re-evaluate
/// the body frequently).
@MainActor
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        // Without a cost limit the NSCache only evicts under system memory pressure, so
        // decoded clipboard bitmaps accumulate unbounded. Cap the decoded footprint and
        // charge each entry its approximate RGBA byte size (Apple: a 0-cost entry never
        // counts against totalCostLimit).
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    static func image(at url: URL) -> NSImage? {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key, cost: estimatedCost(of: image))
        return image
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
