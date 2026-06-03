import AppKit
import SwiftUI

@MainActor
enum SourceAppIconProvider {
    private static var iconCache: [String: NSImage?] = [:]
    private static var paletteCache: [String: [Color]] = [:]

    // Keys are bundle identifiers, so these stay in the tens in practice; the cap is a
    // hard ceiling against pathological growth from many transient unbundled sources.
    private static let cacheEntryLimit = 256

    private static func evictIfNeeded() {
        if iconCache.count > cacheEntryLimit { iconCache.removeAll(keepingCapacity: true) }
        if paletteCache.count > cacheEntryLimit { paletteCache.removeAll(keepingCapacity: true) }
    }

    static func icon(for item: ClipboardItem) -> NSImage? {
        let key = cacheKey(for: item)
        if let cached = iconCache[key] {
            return cached
        }

        let resolvedIcon: NSImage?
        if let path = item.sourceAppPath, FileManager.default.fileExists(atPath: path) {
            resolvedIcon = NSWorkspace.shared.icon(forFile: path)
        } else if let bundleIdentifier = item.sourceBundleIdentifier,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            resolvedIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else if let runningApplication = NSWorkspace.shared.runningApplications.first(where: { application in
            application.localizedName == item.sourceApp
        }), let url = runningApplication.bundleURL {
            resolvedIcon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            resolvedIcon = nil
        }

        let preparedIcon = preparedForDisplay(resolvedIcon)
        evictIfNeeded()
        iconCache[key] = preparedIcon
        return preparedIcon
    }

    static func accentColor(for item: ClipboardItem, fallback: Color) -> Color {
        accentPalette(for: item, fallback: fallback).first ?? fallback
    }

    static func accentPalette(for item: ClipboardItem, fallback: Color) -> [Color] {
        let key = cacheKey(for: item)
        if let cached = paletteCache[key] {
            return cached
        }

        guard let icon = icon(for: item) else {
            return [fallback]
        }

        let colors = dominantPalette(in: icon)
        let palette = colors.isEmpty ? [fallback] : colors.map { Color(nsColor: $0) }
        evictIfNeeded()
        paletteCache[key] = palette
        return palette
    }

    private static func cacheKey(for item: ClipboardItem) -> String {
        item.sourceBundleIdentifier ?? item.sourceAppPath ?? item.sourceApp
    }

    private static func preparedForDisplay(_ image: NSImage?) -> NSImage? {
        guard let image else { return nil }
        guard let copy = image.copy() as? NSImage else { return image }
        copy.size = NSSize(width: 256, height: 256)
        return copy
    }

    private static func dominantPalette(in image: NSImage) -> [NSColor] {
        let sampleSize = NSSize(width: 26, height: 26)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(sampleSize.width),
            pixelsHigh: Int(sampleSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return []
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: sampleSize), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var buckets = Array(repeating: ColorBucket(), count: 12)

        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let alpha = color.alphaComponent
                let saturation = max(color.redComponent, color.greenComponent, color.blueComponent) - min(color.redComponent, color.greenComponent, color.blueComponent)
                let brightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                guard alpha > 0.20, saturation > 0.16, brightness > 0.18, brightness < 0.96 else { continue }

                var hue: CGFloat = 0
                var hueSaturation: CGFloat = 0
                var hueBrightness: CGFloat = 0
                var hueAlpha: CGFloat = 0
                color.getHue(&hue, saturation: &hueSaturation, brightness: &hueBrightness, alpha: &hueAlpha)

                let bucketIndex = min(buckets.count - 1, max(0, Int((hue * CGFloat(buckets.count)).rounded(.down))))
                let pixelWeight = alpha * max(0.20, hueSaturation) * max(0.28, hueBrightness)
                buckets[bucketIndex].add(color: color, weight: pixelWeight)
            }
        }

        let rankedColors = buckets
            .filter { $0.weight > 0.05 }
            .sorted { $0.weight > $1.weight }
            .compactMap(\.color)

        var selected: [NSColor] = []
        for color in rankedColors {
            guard selected.allSatisfy({ color.hueDistance(from: $0) > 0.08 }) else { continue }
            selected.append(normalized(color))
            if selected.count == 3 { break }
        }

        if selected.count == 1, let companion = rankedColors.first(where: { selected[0].hueDistance(from: $0) > 0.05 }) {
            selected.append(normalized(companion))
        }

        return selected
    }

    private static func normalized(_ color: NSColor) -> NSColor {
        guard let deviceColor = color.usingColorSpace(.deviceRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        deviceColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            calibratedHue: hue,
            saturation: min(0.88, max(0.46, saturation)),
            brightness: min(0.82, max(0.42, brightness)),
            alpha: 1
        )
    }
}

private struct ColorBucket {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var weight: CGFloat = 0

    mutating func add(color: NSColor, weight: CGFloat) {
        red += color.redComponent * weight
        green += color.greenComponent * weight
        blue += color.blueComponent * weight
        self.weight += weight
    }

    var color: NSColor? {
        guard weight > 0 else { return nil }
        return NSColor(deviceRed: red / weight, green: green / weight, blue: blue / weight, alpha: 1)
    }
}

private extension NSColor {
    func hueDistance(from other: NSColor) -> CGFloat {
        guard
            let lhs = usingColorSpace(.deviceRGB),
            let rhs = other.usingColorSpace(.deviceRGB)
        else {
            return 1
        }

        var leftHue: CGFloat = 0
        var leftSaturation: CGFloat = 0
        var leftBrightness: CGFloat = 0
        var leftAlpha: CGFloat = 0
        lhs.getHue(&leftHue, saturation: &leftSaturation, brightness: &leftBrightness, alpha: &leftAlpha)

        var rightHue: CGFloat = 0
        var rightSaturation: CGFloat = 0
        var rightBrightness: CGFloat = 0
        var rightAlpha: CGFloat = 0
        rhs.getHue(&rightHue, saturation: &rightSaturation, brightness: &rightBrightness, alpha: &rightAlpha)

        let distance = abs(leftHue - rightHue)
        return min(distance, 1 - distance)
    }
}
