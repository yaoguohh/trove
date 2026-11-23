import AppKit
import SwiftUI
@testable import Trove

/// An sRGB color, 0–255 per channel.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: NSColor) {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        r = srgb.redComponent * 255
        g = srgb.greenComponent * 255
        b = srgb.blueComponent * 255
    }

    /// WCAG relative luminance.
    var luminance: Double {
        func linear(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG contrast ratio, 1–21.
    func contrast(with other: RGB) -> Double {
        let (hi, lo) = (max(luminance, other.luminance), min(luminance, other.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    var hex: String { String(format: "#%02X%02X%02X", Int(r.rounded()), Int(g.rounded()), Int(b.rounded())) }

    /// The largest per-channel difference.
    func distance(to other: RGB) -> Double {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
    }
}

/// A measured box in points, top-left origin.
struct Box {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init(_ rect: CGRect) {
        self.init(minX: rect.minX, minY: rect.minY, maxX: rect.maxX, maxY: rect.maxY)
    }

    var midX: Double { (minX + maxX) / 2 }
    var midY: Double { (minY + maxY) / 2 }
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var rect: CGRect { CGRect(x: minX, y: minY, width: width, height: height) }

    func union(_ other: Box) -> Box {
        Box(minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }
}

/// A view rendered at 2x onto an opaque backdrop, with measurements over its pixels. Everything is in
/// points with a top-left origin; edges are refined to sub-pixel precision from the edge pixel's
/// coverage, so a measured box matches what the eye sees, not the view's layout frame.
@MainActor
final class AuditCanvas {
    let name: String
    let scale: Double = 2
    let size: CGSize
    let backdrop: RGB
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let bytesPerRow: Int
    private let bytes: [UInt8]
    private let image: CGImage
    private var marks: [(rect: CGRect, color: NSColor)] = []
    private var crops: [(rect: CGRect, name: String)] = []

    init(name: String, view: NSView, backdrop: NSColor) {
        self.name = name
        self.backdrop = RGB(backdrop)
        size = view.bounds.size
        pixelWidth = Int((size.width * scale).rounded())
        pixelHeight = Int((size.height * scale).rounded())
        let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(backdrop.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        if view.isFlipped {
            // A flipped root view (NSHostingView) keeps a flipped layer; undo it so row 0 is the top.
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: 1, y: -1)
        }
        context.scaleBy(x: scale, y: scale)
        view.layer?.render(in: context)
        bytesPerRow = context.bytesPerRow
        let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
        bytes = Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * pixelHeight))
        image = context.makeImage()!
    }

    /// For an image file (the app icon): drawn at `size` points onto the backdrop.
    init(name: String, image source: NSImage, size: CGSize, backdrop: NSColor) {
        self.name = name
        self.backdrop = RGB(backdrop)
        self.size = size
        pixelWidth = Int((size.width * scale).rounded())
        pixelHeight = Int((size.height * scale).rounded())
        let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(backdrop.usingColorSpace(.sRGB)!.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        var rect = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)
        if let cg = source.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            context.interpolationQuality = .high
            context.draw(cg, in: rect)
        }
        bytesPerRow = context.bytesPerRow
        let pointer = context.data!.assumingMemoryBound(to: UInt8.self)
        bytes = Array(UnsafeBufferPointer(start: pointer, count: bytesPerRow * pixelHeight))
        image = context.makeImage()!
    }

    // MARK: Pixels

    func pixel(_ x: Int, _ y: Int) -> RGB {
        let cx = min(max(x, 0), pixelWidth - 1)
        let cy = min(max(y, 0), pixelHeight - 1)
        let offset = cy * bytesPerRow + cx * 4
        return RGB(r: Double(bytes[offset]), g: Double(bytes[offset + 1]), b: Double(bytes[offset + 2]))
    }

    /// The color at a point (the pixel under it).
    func color(at point: CGPoint) -> RGB {
        pixel(Int(point.x * scale), Int(point.y * scale))
    }

    private func pixelRange(_ rect: CGRect) -> (x: Range<Int>, y: Range<Int>) {
        // An empty intersection or inset is `.null`, whose origin is infinite.
        guard !rect.isNull, !rect.isInfinite, rect.minX.isFinite, rect.minY.isFinite else { return (0..<0, 0..<0) }
        let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
        let x1 = min(pixelWidth, Int((rect.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
        let y1 = min(pixelHeight, Int((rect.maxY * scale).rounded(.up)))
        return (x0..<max(x0, x1), y0..<max(y0, y1))
    }

    /// The most common color on the rect's one-pixel border: the surface the rect's content sits on.
    func background(of rect: CGRect) -> RGB {
        let (xs, ys) = pixelRange(rect)
        guard !xs.isEmpty, !ys.isEmpty else { return backdrop }
        var counts: [Int: (Int, RGB)] = [:]
        func add(_ x: Int, _ y: Int) {
            let c = pixel(x, y)
            let key = (Int(c.r) >> 2) << 12 | (Int(c.g) >> 2) << 6 | (Int(c.b) >> 2)
            counts[key, default: (0, c)].0 += 1
        }
        for x in xs {
            add(x, ys.lowerBound)
            add(x, ys.upperBound - 1)
        }
        for y in ys {
            add(xs.lowerBound, y)
            add(xs.upperBound - 1, y)
        }
        return counts.values.max { $0.0 < $1.0 }?.1 ?? backdrop
    }

    // MARK: Ink

    /// The visible bounds of whatever in `rect` differs from `bg` (default: the rect's border color).
    /// A pixel counts when its difference reaches `relative` of the strongest pixel's, and at least
    /// `minDiff`; each edge is then moved by the edge pixel's partial coverage.
    /// `ignore` is a second background, e.g. the backdrop showing past a rounded corner.
    /// `flatEdges`: the thing is a filled shape, so an edge pixel's coverage is measured against the
    /// pixel just inside it rather than against the strongest ink in the rect. A faint-edged shape with
    /// bright text in it (a glass card) otherwise reads as up to half a point smaller.
    func ink(in rect: CGRect, bg: RGB? = nil, ignore: RGB? = nil, within: ((CGPoint) -> Bool)? = nil, minDiff: Double = 6, relative: Double = 0.2, flatEdges: Bool = false) -> Box? {
        let (xs, ys) = pixelRange(rect)
        guard !xs.isEmpty, !ys.isEmpty else { return nil }
        let base = bg ?? background(of: rect)
        var cols = [Double](repeating: 0, count: xs.count)
        var rows = [Double](repeating: 0, count: ys.count)
        var strongest = 0.0
        for (j, y) in ys.enumerated() {
            for (i, x) in xs.enumerated() {
                let p = pixel(x, y)
                if let ignore, p.distance(to: ignore) < 30 { continue }
                if let within, !within(CGPoint(x: (Double(x) + 0.5) / scale, y: (Double(y) + 0.5) / scale)) { continue }
                let d = p.distance(to: base)
                cols[i] = max(cols[i], d)
                rows[j] = max(rows[j], d)
                strongest = max(strongest, d)
            }
        }
        guard strongest >= minDiff else { return nil }
        let threshold = max(minDiff, relative * strongest)
        guard let c0 = cols.firstIndex(where: { $0 >= threshold }),
              let c1 = cols.lastIndex(where: { $0 >= threshold }),
              let r0 = rows.firstIndex(where: { $0 >= threshold }),
              let r1 = rows.lastIndex(where: { $0 >= threshold }) else { return nil }
        func coverage(_ value: Double, inside: Double?) -> Double {
            let full = flatEdges ? max(value, inside ?? value) : strongest
            return min(1, value / full)
        }
        let left = Double(xs.lowerBound + c0) + 1 - coverage(cols[c0], inside: cols.indices.contains(c0 + 1) ? cols[c0 + 1] : nil)
        let right = Double(xs.lowerBound + c1) + coverage(cols[c1], inside: c1 > 0 ? cols[c1 - 1] : nil)
        let top = Double(ys.lowerBound + r0) + 1 - coverage(rows[r0], inside: rows.indices.contains(r0 + 1) ? rows[r0 + 1] : nil)
        let bottom = Double(ys.lowerBound + r1) + coverage(rows[r1], inside: r1 > 0 ? rows[r1 - 1] : nil)
        return Box(minX: left / scale, minY: top / scale, maxX: right / scale, maxY: bottom / scale)
    }

    /// The contrast-weighted center of what differs from `bg`: where the eye puts the middle of an
    /// asymmetric drawing, as opposed to the center of its bounding box.
    func centroid(in rect: CGRect, bg: RGB, within: ((CGPoint) -> Bool)? = nil, minDiff: Double = 12) -> CGPoint? {
        let (xs, ys) = pixelRange(rect)
        var total = 0.0, sx = 0.0, sy = 0.0
        for y in ys {
            for x in xs {
                let point = CGPoint(x: (Double(x) + 0.5) / scale, y: (Double(y) + 0.5) / scale)
                if let within, !within(point) { continue }
                let d = pixel(x, y).distance(to: bg)
                guard d >= minDiff else { continue }
                total += d
                sx += d * point.x
                sy += d * point.y
            }
        }
        return total > 0 ? CGPoint(x: sx / total, y: sy / total) : nil
    }

    enum Axis { case horizontal, vertical }

    /// Splits `rect` into runs of content along `axis`, separated by at least `gap` points of
    /// background, and returns each run's ink box.
    func segments(in rect: CGRect, axis: Axis = .horizontal, bg: RGB? = nil, minDiff: Double = 10, gap: Double = 4, flatEdges: Bool = false) -> [Box] {
        let (xs, ys) = pixelRange(rect)
        guard !xs.isEmpty, !ys.isEmpty else { return [] }
        let base = bg ?? background(of: rect)
        let lanes = axis == .horizontal ? xs : ys
        var hit = [Bool](repeating: false, count: lanes.count)
        for (i, lane) in lanes.enumerated() {
            let cross = axis == .horizontal ? ys : xs
            for c in cross {
                let p = axis == .horizontal ? pixel(lane, c) : pixel(c, lane)
                if p.distance(to: base) >= minDiff {
                    hit[i] = true
                    break
                }
            }
        }
        let gapPixels = Int((gap * scale).rounded())
        var runs: [Range<Int>] = []
        var start: Int?
        var lastHit = -1_000_000
        for (i, isHit) in hit.enumerated() where isHit {
            if let s = start, i - lastHit > gapPixels {
                runs.append(s..<(lastHit + 1))
                start = i
            } else if start == nil {
                start = i
            }
            lastHit = i
        }
        if let s = start { runs.append(s..<(lastHit + 1)) }
        return runs.compactMap { run in
            let lo = Double(lanes.lowerBound + run.lowerBound) / scale
            let hi = Double(lanes.lowerBound + run.upperBound) / scale
            let sub = axis == .horizontal
                ? CGRect(x: lo - 0.5, y: rect.minY, width: hi - lo + 1, height: rect.height)
                : CGRect(x: rect.minX, y: lo - 0.5, width: rect.width, height: hi - lo + 1)
            return ink(in: sub.intersection(rect), bg: base, minDiff: minDiff, relative: 0, flatEdges: flatEdges)
        }
    }

    /// The top of a text run's ink and its baseline: the bottom of the densest band of rows, so
    /// descenders (p, y, g) don't pull it down.
    func textLine(_ box: Box, bg: RGB) -> (top: Double, baseline: Double, center: Double) {
        let (xs, ys) = pixelRange(box.rect)
        guard !xs.isEmpty, !ys.isEmpty else { return (box.minY, box.maxY, box.midY) }
        var strongest = 0.0
        for y in ys { for x in xs { strongest = max(strongest, pixel(x, y).distance(to: bg)) } }
        var counts: [Int] = []
        for y in ys {
            var n = 0
            for x in xs where pixel(x, y).distance(to: bg) >= strongest * 0.5 { n += 1 }
            counts.append(n)
        }
        let peak = counts.max() ?? 0
        let last = counts.lastIndex { Double($0) >= Double(peak) * 0.3 } ?? (counts.count - 1)
        let baseline = Double(ys.lowerBound + last + 1) / scale
        return (box.minY, baseline, (box.minY + baseline) / 2)
    }

    /// Outer bounds of the filled shape under `seed`: scans out along the seed's row and column until
    /// a pixel looks more like `outside` than like the fill at the seed.
    func extent(seed: CGPoint, outside: RGB, fill reference: RGB? = nil) -> Box {
        let sx = Int(seed.x * scale)
        let sy = Int(seed.y * scale)
        let fill = reference ?? pixel(sx, sy)
        let full = fill.distance(to: outside)
        func inside(_ x: Int, _ y: Int) -> Bool { pixel(x, y).distance(to: outside) >= full * 0.5 }
        var left = sx, right = sx, top = sy, bottom = sy
        while left > 0, inside(left - 1, sy) { left -= 1 }
        while right < pixelWidth - 1, inside(right + 1, sy) { right += 1 }
        while top > 0, inside(sx, top - 1) { top -= 1 }
        while bottom < pixelHeight - 1, inside(sx, bottom + 1) { bottom += 1 }
        return Box(minX: Double(left) / scale, minY: Double(top) / scale, maxX: Double(right + 1) / scale, maxY: Double(bottom + 1) / scale)
    }

    // MARK: Output

    func mark(_ box: Box?, _ color: NSColor = .systemPink) {
        guard let box else { return }
        marks.append((box.rect, color))
    }

    func mark(_ rect: CGRect, _ color: NSColor) {
        marks.append((rect, color))
    }

    /// Also writes `<name>-<crop>.png`: that region of the marked render, enlarged 2x again.
    func crop(_ rect: CGRect, _ name: String) {
        crops.append((rect, name))
    }

    /// Writes `<name>.png` (the clean render) and `<name>-marked.png` (with the measured boxes).
    func write(to directory: URL) throws {
        try png(image).write(to: directory.appendingPathComponent("\(name).png"))
        let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setLineWidth(1)
        for mark in marks {
            // Top-left points → bottom-left pixels, stroked on the pixel grid just outside the box.
            let r = mark.rect
            let px = CGRect(x: r.minX * scale - 0.5, y: Double(pixelHeight) - r.maxY * scale - 0.5,
                            width: r.width * scale + 1, height: r.height * scale + 1)
            context.setStrokeColor(mark.color.withAlphaComponent(0.9).cgColor)
            context.stroke(px)
        }
        let marked = context.makeImage()!
        try png(marked).write(to: directory.appendingPathComponent("\(name)-marked.png"))
        for crop in crops {
            let px = CGRect(x: crop.rect.minX * scale, y: crop.rect.minY * scale, width: crop.rect.width * scale, height: crop.rect.height * scale).integral
            guard let part = marked.cropping(to: px) else { continue }
            let zoom = 2
            let big = CGContext(
                data: nil, width: part.width * zoom, height: part.height * zoom, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            big.interpolationQuality = .none
            big.draw(part, in: CGRect(x: 0, y: 0, width: part.width * zoom, height: part.height * zoom))
            try png(big.makeImage()!).write(to: directory.appendingPathComponent("\(name)-\(crop.name).png"))
        }
    }

    private func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }
}

/// The audit's findings as a Markdown report: one table per surface.
@MainActor
final class AuditReport {
    private var lines: [String] = []
    private var tableOpen = false
    private(set) var failures = 0

    /// For lines through the visible edges of text and symbols: every glyph carries its own side bearing
    /// (about 0.5–1.5pt at these sizes, varying with the letter or symbol), so things laid out on one
    /// line show that much spread in their ink.
    static let glyphTolerance: Double = 1.5
    /// For text centered in a frame (half the difference of its two side bearings), and for a symbol
    /// centered on a text line (each symbol's ink sits a little differently in its own box).
    static let glyphCenterTolerance: Double = 0.75

    func section(_ title: String, _ note: String? = nil) {
        lines.append("")
        lines.append("## \(title)")
        if let note { lines.append(""); lines.append(note) }
        lines.append("")
        lines.append("| 项 | 实测 | 应为 | 偏差 | |")
        lines.append("|---|---|---|---|---|")
        tableOpen = true
    }

    /// A measured value against the one the layout implies; within `tolerance` points passes.
    func check(_ item: String, _ measured: Double?, _ expected: Double, tolerance: Double = 0.5) {
        guard let measured else {
            lines.append("| \(item) | 未测到 | \(fmt(expected)) | | ⚠️ |")
            failures += 1
            return
        }
        let delta = measured - expected
        let pass = abs(delta) <= tolerance
        if !pass { failures += 1 }
        lines.append("| \(item) | \(fmt(measured)) | \(fmt(expected)) | \(delta >= 0 ? "+" : "")\(fmt(delta)) | \(pass ? "✓" : "✗") |")
    }

    /// Several things that should sit on one line (a column of icon centers, a run of text starts).
    /// With `at`, the line must also be where the layout puts it: every value within `tolerance` of it.
    func line(_ item: String, _ values: [(String, Double?)], at expected: Double? = nil, tolerance: Double = 0.5) {
        let measured = values.compactMap(\.1)
        let target = expected.map { "在 \(fmt($0))" } ?? "同一条线"
        guard let lo = measured.min(), let hi = measured.max() else {
            lines.append("| \(item) | 未测到 | \(target) | | ⚠️ |")
            failures += 1
            return
        }
        let spread = expected.map { e in measured.map { abs($0 - e) }.max() ?? 0 } ?? (hi - lo)
        let pass = spread <= tolerance && measured.count == values.count
        if !pass { failures += 1 }
        let detail = values.map { "\($0.0) \($0.1.map(fmt) ?? "—")" }.joined(separator: "，")
        lines.append("| \(item) | \(detail) | \(target) | 差 \(fmt(spread)) | \(pass ? "✓" : "✗") |")
    }

    /// A measured value that must reach `minimum` (a contrast ratio, say).
    func atLeast(_ item: String, _ measured: Double?, _ minimum: Double) {
        guard let measured else {
            lines.append("| \(item) | 未测到 | ≥ \(fmt(minimum)) | | ⚠️ |")
            failures += 1
            return
        }
        let pass = measured >= minimum
        if !pass { failures += 1 }
        lines.append("| \(item) | \(fmt(measured)) | ≥ \(fmt(minimum)) | \(fmt(measured - minimum)) | \(pass ? "✓" : "✗") |")
    }

    func info(_ item: String, _ text: String) {
        lines.append("| \(item) | \(text) | | | ℹ︎ |")
    }

    func write(to url: URL) throws {
        let header = "# 布局测量\n\n2 倍渲染，按看得见的像素量，单位 pt；偏差超过 0.5pt 记 ✗。比较文字和符号边缘的对齐线放宽到 1.5pt、文字居中和符号对文字的中线放宽到 0.75pt：每个字形自带 0.5–1.5pt 的左右留白，随字母和符号变。\n"
        try (header + lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.1f", value)
    }
}
