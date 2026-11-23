import AppKit
import SwiftUI
import Testing
@testable import Trove

/// Renders each surface and measures it (see `AuditCanvas`). Opt-in: runs only with
/// `TROVE_LAYOUT_AUDIT=<output directory>`, and writes `report.md` plus the renders there.
@MainActor
@Suite(.serialized)
struct LayoutAuditTests {
    private static let output = ProcessInfo.processInfo.environment["TROVE_LAYOUT_AUDIT"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }
    private static let report = AuditReport()

    private static func prepare() throws -> URL? {
        guard let output else { return nil }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .darkAqua)
        return output
    }

    /// Where the panel shows for measuring: the built-in display, else any 2x one. On a 1x display
    /// text and shapes round to whole points, which reads as 0.5–2pt of misalignment.
    private static var retinaScreen: NSScreen? {
        NSScreen.screens.first { $0.backingScaleFactor >= 2 && $0.localizedName.contains("Built-in") }
            ?? NSScreen.screens.first { $0.backingScaleFactor >= 2 }
    }

    /// The glass renders as flat gray off-screen; hiding it leaves the dark backdrop, which is close to
    /// what the glass looks like on screen.
    private static func hideGlass(in view: NSView) {
        for sub in view.subviews {
            if sub is NSVisualEffectView { sub.isHidden = true }
            hideGlass(in: sub)
        }
    }

    /// The bounds of a filled shape: horizontal edges along `row`, vertical edges along `column`, both
    /// away from the rounded corners.
    private static func shape(_ canvas: AuditCanvas, row: CGPoint, column: CGPoint, outside: RGB) -> Box {
        // The fill is read at `row`, near the shape's edge; the column may cross text or a divider.
        let fill = canvas.color(at: row)
        let h = canvas.extent(seed: row, outside: outside, fill: fill)
        let v = canvas.extent(seed: column, outside: outside, fill: fill)
        return Box(minX: h.minX, minY: v.minY, maxX: h.maxX, maxY: v.maxY)
    }

    /// A screenshot-like picture, wider than a card's body: a white page with a few gray rows.
    private static func samplePNG() -> Data {
        let size = NSSize(width: 800, height: 500)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        for row in 0..<6 { NSRect(x: 40, y: 420 - row * 64, width: 720 - row * 60, height: 22).fill() }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private static func sampleStore(root: URL) -> ClipStore {
        let store = ClipStore(files: ClipFiles(root: root))
        let finder = "/System/Library/CoreServices/Finder.app"
        // Copied five minutes ago, so its time reads "5 分钟前": the digit sits on the baseline, which a
        // time of all ideographs ("现在") doesn't show.
        let id = UUID()
        let png = samplePNG()
        if let stored = try? ImageFiles.writeFiles(id: id, png: png, directory: store.files.imageDirectory) {
            store.addPreparedImage(id: id, files: stored, contentHash: Clip.hash(png), sourceApp: "Finder", sourceBundleIdentifier: nil, sourceAppPath: finder, createdAt: Date().addingTimeInterval(-300))
        }
        store.add(text: "https://github.com/jaywcjlove/PermissionFlow", sourceApp: "Finder", sourceAppPath: finder)
        store.add(text: "Hello, world. The quick brown fox jumps over the lazy dog.", sourceApp: "Finder", sourceAppPath: finder)
        store.add(text: "上面发现的问题要找专业标准设计，或者方案？或者是否存在标准组件？", sourceApp: "Finder", sourceAppPath: finder)
        return store
    }

    // MARK: Panel

    /// Every 2x display, the built-in one first: each may get a different card size.
    private static var retinaScreens: [NSScreen] {
        let screens = NSScreen.screens.filter { $0.backingScaleFactor >= 2 }
        return screens.filter { $0.localizedName.contains("Built-in") } + screens.filter { !$0.localizedName.contains("Built-in") }
    }

    @Test func panel() async throws {
        guard let output = try Self.prepare() else { return }
        for (index, screen) in Self.retinaScreens.enumerated() {
            try await Self.measurePanel(on: screen, name: index == 0 ? "panel" : "panel-\(index + 1)", output: output)
        }
    }

    private static func measurePanel(on screen: NSScreen, name canvasName: String, output: URL) async throws {
        let root = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Self.sampleStore(root: root)
        let pasteboard = NSPasteboard.withUniqueName()
        let clipPasteboard = ClipPasteboard(store: store, monitor: ClipboardMonitor(store: store, pasteboard: pasteboard), pasteboard: pasteboard)
        let controller = PanelController(store: store, pasteboard: clipPasteboard)
        controller.show(on: screen)
        try await Task.sleep(for: .milliseconds(900))
        let window = try #require(NSApp.windows.first { $0.isVisible && $0 is PanelWindow })
        let content = try #require(window.contentView)
        Self.hideGlass(in: content)
        let canvas = AuditCanvas(name: canvasName, view: content, backdrop: NSColor(Theme.Surface.coal))
        let report = Self.report
        let W = canvas.size.width
        let H = canvas.size.height
        let inset = PanelLayout.inset
        let bar = PanelLayout.toolbarHeight
        let barMid = inset + bar / 2

        // Toolbar: reset, search, pinboard chips, plus, more.
        report.section("面板 · 工具栏", "面板 \(Int(W))×\(Int(H))，在\(window.screen?.localizedName ?? "未知屏幕")（\(Int(window.screen?.backingScaleFactor ?? 0)) 倍）上。工具栏控件框高 \(Int(bar))，中线 y=\(Int(barMid))。")
        let toolbar = canvas.segments(in: CGRect(x: 4, y: inset - 3, width: W - 8, height: bar + 6), gap: 11)
        toolbar.forEach { canvas.mark($0) }
        let reset = toolbar.first
        let more = toolbar.last
        let search = toolbar.count > 1 ? toolbar[1] : nil
        let plus = toolbar.count > 2 ? toolbar[toolbar.count - 2] : nil
        let chips = toolbar.count > 4 ? Array(toolbar[2..<(toolbar.count - 2)]) : []
        canvas.mark(CGRect(x: inset, y: inset, width: bar, height: bar), .systemTeal)
        canvas.mark(CGRect(x: W - inset - bar, y: inset, width: bar, height: bar), .systemTeal)
        report.check("刷新图标 中心 x（框中心）", reset?.midX, inset + bar / 2)
        report.check("刷新图标 中心 y", reset?.midY, barMid)
        report.check("更多图标 中心 x（框中心）", more?.midX, W - inset - bar / 2)
        report.check("更多图标 中心 y", more?.midY, barMid)
        report.info("两端图标的可见边距", String(format: "左 %.1f，右 %.1f（到面板边）", reset?.minX ?? 0, W - (more?.maxX ?? 0)))
        report.check("加号图标 中心 y", plus?.midY, barMid)
        if let search {
            let outside = canvas.background(of: CGRect(x: search.minX - 6, y: inset, width: 4, height: bar))
            let capsule = Self.shape(canvas, row: CGPoint(x: search.minX + 4, y: barMid), column: CGPoint(x: search.midX, y: barMid), outside: outside)
            report.check("搜索框 顶", capsule.minY, inset)
            report.check("搜索框 底", capsule.maxY, inset + bar)
            let fill = canvas.color(at: CGPoint(x: capsule.minX + 6, y: barMid))
            // Inside the rounded ends, so the capsule's own hairline isn't measured as content.
            let parts = canvas.segments(in: CGRect(x: capsule.minX + 8, y: capsule.minY + 3, width: capsule.width - 16, height: capsule.height - 6), bg: fill, minDiff: 20, gap: 4)
            parts.forEach { canvas.mark($0, .systemYellow) }
            if parts.count >= 2, let word = parts.last {
                // The last word only: the first one carries the insertion point of the focused field.
                let glass = parts[0]
                let text = canvas.textLine(word, bg: fill)
                report.info("放大镜 可见左边距（到胶囊左缘）", String(format: "%.1f（框内边距 12，加上符号自带的留白）", glass.minX - capsule.minX))
                report.check("放大镜 中心 y", glass.midY, capsule.midY)
                report.check("占位文字 字身中线 y", text.center, capsule.midY)
                report.check("放大镜 中心 y（文字字身中线）", glass.midY, text.center)
                report.info("占位文字 右边距", String(format: "%.1f（文字框宽 150，右侧留白随文字长度变）", capsule.maxX - word.maxX))
            }
            canvas.crop(CGRect(x: search.minX - 8, y: 4, width: min(W - search.minX, 420), height: bar + 16), "search")
        }
        for (i, chip) in chips.enumerated() {
            let parts = canvas.segments(in: chip.rect.insetBy(dx: -1, dy: -1), gap: 3)
            guard parts.count >= 2 else { continue }
            let bg = canvas.background(of: chip.rect.insetBy(dx: -2, dy: -2))
            report.check("收藏板 \(i + 1) 圆点 中心 y", parts[0].midY, barMid)
            report.check("收藏板 \(i + 1) 文字 字身中线 y", canvas.textLine(parts[1], bg: bg).center, barMid)
        }
        canvas.crop(CGRect(x: 0, y: 0, width: 120, height: 120), "left")
        canvas.crop(CGRect(x: W - 120, y: 0, width: 120, height: 80), "right")

        // Cards. They are panes of the glass, a few levels off it and tinted unevenly by the corner glow, so
        // they are found as whatever isn't glass: across the row at mid-height, then down each one.
        let glassColor = canvas.color(at: CGPoint(x: 4, y: H / 2))
        // Clear of the panel's own hairline border.
        // A low threshold, so the anti-aliased half pixel at a card's faint edge still counts.
        let across = canvas.segments(in: CGRect(x: 4, y: H / 2 + 29, width: W - 8, height: 2), bg: glassColor, minDiff: 2, gap: 6, flatEdges: true)
        var cards: [Box] = []
        for column in across.prefix(4) {
            let down = canvas.segments(in: CGRect(x: column.midX - 1, y: inset + bar + 2, width: 2, height: H - inset - bar - 6), axis: .vertical, bg: glassColor, minDiff: 2, gap: 6, flatEdges: true)
            if let span = down.max(by: { $0.height < $1.height }) {
                cards.append(Box(minX: column.minX, minY: span.minY, maxX: column.maxX, maxY: span.maxY))
            }
        }
        try #require(cards.count == 4)
        let metrics = CardMetrics(size: .init(screenHeight: screen.frame.height))
        let gap = PanelLayout.inset
        // The selected card's outer ring reads as part of its shape; place it from its neighbor.
        cards[0] = Box(minX: cards[1].minX - gap - cards[1].width, minY: cards[1].minY, maxX: cards[1].minX - gap, maxY: cards[1].maxY)
        report.section("面板 · 卡片", "\(metrics.size) 号卡片，" + String(format: "%.0f×%.0f，左右和底边内边距 %.0f，信息行 %.0f（来源图标），行上下各 %.0f，卡片间距 %.0f。", metrics.width, metrics.height, metrics.contentInset, metrics.iconSize, metrics.metaSpace, gap))
        cards.forEach { canvas.mark($0, .systemTeal) }
        report.info("工具栏这一行的实际高度", String(format: "%.1f（卡片顶 − 12 − 12）", cards[1].minY - 2 * inset))
        report.check("卡片 顶（搜索框底 + 12）", cards[1].minY, inset + bar + inset)
        report.check("卡片 底到面板底", H - cards[1].maxY, inset)
        report.check("卡片 高", cards[1].height, metrics.height)
        report.check("第一张卡 左", cards[0].minX, inset)
        report.check("卡片间距", cards[2].minX - cards[1].maxX, gap)
        report.info("选中外圈到面板边", String(format: "左 %.1f（外圈 4pt）", cards[0].minX - 4))

        // The selected card's accent hairline runs through its corners; its insides match the others.
        let cardInset = metrics.contentInset
        for (index, card) in cards.enumerated() where index > 0 {
            let name = ["卡片 1（中文，选中）", "卡片 2（英文）", "卡片 3（链接）", "卡片 4（图片）"][index]
            let space = metrics.metaSpace
            // The meta row: source icon and name at the left, the time at the right. The corner glow
            // shades the card unevenly, so each piece is read against the card right beside it.
            let rowMid = card.minY + space + metrics.iconSize / 2
            let iconBg = canvas.color(at: CGPoint(x: card.minX + 6, y: rowMid))
            let icon = canvas.ink(in: CGRect(x: card.minX + 4, y: card.minY + space - 3, width: cardInset + metrics.iconSize - 1, height: metrics.iconSize + 6), bg: iconBg, minDiff: 20)
            let restX = (icon?.maxX ?? card.minX + cardInset + metrics.iconSize) + 2
            let rowBg = canvas.color(at: CGPoint(x: restX + 1, y: rowMid))
            let parts = canvas.segments(in: CGRect(x: restX, y: card.minY + space - 3, width: card.maxX - 4 - restX, height: metrics.iconSize + 6), bg: rowBg, minDiff: 40, gap: 4)
            canvas.mark(icon)
            parts.forEach { canvas.mark($0) }
            let title = parts.first
            let time = parts.count > 1 ? parts.last : nil
            report.check("\(name) 来源图标 左（内边距）", icon.map { $0.minX - card.minX }, cardInset)
            report.check("\(name) 来源图标 顶（行上方间距）", icon.map { $0.minY - card.minY }, space)
            // Small icon sizes come from the icon's own small bitmaps, drawn with less margin.
            report.check("\(name) 来源图标 可见边长", icon?.width, metrics.iconSize, tolerance: 1)
            report.check("\(name) 名称 字身中线 y（图标中心）", title.map { canvas.textLine($0, bg: rowBg).center }, icon?.midY ?? 0, tolerance: AuditReport.glyphCenterTolerance)
            report.check("\(name) 时间 右（内边距）", time.map { card.maxX - $0.maxX }, cardInset, tolerance: AuditReport.glyphTolerance)
            // Name and time on one baseline, read where the time starts with a digit ("5 分钟前"):
            // ideographs sit a little below the Latin baseline.
            if index == 3, let time, let digit = canvas.ink(in: CGRect(x: time.minX - 1, y: time.minY - 1, width: 6, height: time.height + 2), bg: rowBg, minDiff: 40) {
                report.check("\(name) 时间 基线（名称基线）", digit.maxY, title.map { canvas.textLine($0, bg: rowBg).baseline } ?? 0)
            }
            report.info("\(name) 信息行占高", String(format: "%.1f（顶边到图标底，再加行下间距 %.1f）", (icon?.maxY ?? 0) - card.minY + space, space))

            let rowBottom = card.minY + space + metrics.iconSize
            let body = CGRect(x: card.minX + 4, y: rowBottom + 2, width: card.width - 8, height: card.maxY - rowBottom - 6)
            let bodyBg = canvas.color(at: CGPoint(x: card.minX + 6, y: rowBottom + space / 2))
            let bodyInk = canvas.segments(in: body, axis: .vertical, bg: bodyBg, minDiff: 40, gap: 3)
            let firstBody = bodyInk.first.flatMap { canvas.segments(in: $0.rect.insetBy(dx: -1, dy: -1), bg: bodyBg, minDiff: 40, gap: 5).first }
            canvas.mark(firstBody, .systemYellow)
            if index == 1 {
                report.info("\(name) 信息行到正文", String(format: "可见间隔 %.1f（相隔 %.0f，加上行高里字形上方的空白）", (bodyInk.first?.minY ?? 0) - rowBottom, space))
            }
            if index == 3, let picture = bodyInk.first {
                // The picture: rounded and outlined at its fitted size, at the body's top-left.
                canvas.mark(picture, .systemYellow)
                report.line("\(name) 信息行上下间距", [("上（顶边到图标）", icon.map { $0.minY - card.minY }), ("下（图标到图片）", icon.map { picture.minY - $0.maxY })], at: space)
                report.line("\(name) 左缘（距卡片左缘）", [("来源图标", icon.map { $0.minX - card.minX }), ("图片", picture.minX - card.minX)], at: cardInset)
                report.check("\(name) 图片 宽（填满内容宽）", picture.width, card.width - 2 * cardInset)
            }
            if index == 1 {
                report.line("\(name) 左缘（距卡片左缘）", [("来源图标", icon.map { $0.minX - card.minX }), ("正文", firstBody.map { $0.minX - card.minX })], at: cardInset, tolerance: AuditReport.glyphTolerance)
            }
            if index == 2 {
                // The link's site icon: a tinted rounded square with a link glyph. A thin strip near its
                // left edge, above the URL line, finds it vertically; the shape scan then gives its edges.
                // Seeded where the layout puts it (the body's top-left); the scan finds its edges against
                // the card just left of it.
                let left = card.minX + cardInset
                let seedY = rowBottom + space + metrics.siteIconSize / 2
                let beside = canvas.color(at: CGPoint(x: left - 5, y: seedY))
                let square = Self.shape(canvas, row: CGPoint(x: left + 3, y: seedY), column: CGPoint(x: left + metrics.siteIconSize / 2, y: seedY), outside: beside).rect
                let squareFill = canvas.color(at: CGPoint(x: square.minX + 3, y: square.midY))
                let glyph = canvas.ink(in: square.insetBy(dx: 2, dy: 2), bg: squareFill, relative: 0.35)
                canvas.mark(square, .systemTeal)
                canvas.mark(glyph)
                report.check("链接图标 字形中心 x（方块中心）", glyph?.midX, square.midX)
                report.check("链接图标 字形中心 y（方块中心）", glyph?.midY, square.midY)
                let heroArea = CGRect(x: square.maxX + 4, y: square.minY - 4, width: card.maxX - square.maxX - 18, height: square.height + 8)
                let heroBg = canvas.color(at: CGPoint(x: square.maxX + 3, y: square.midY))
                let hero = canvas.segments(in: heroArea, axis: .vertical, bg: heroBg, minDiff: 40, gap: 2).first
                canvas.mark(hero, .systemYellow)
                report.check("链接标题首行 字身中线 y（图标中心）", hero.map { canvas.textLine($0, bg: heroBg).center }, square.midY, tolerance: AuditReport.glyphCenterTolerance)
                // The URL line: the first line below the icon (a long title wraps beside the icon).
                let route = bodyInk.first { $0.minY > square.maxY + 1 }.flatMap { canvas.segments(in: $0.rect.insetBy(dx: -1, dy: -1), bg: bodyBg, minDiff: 30, gap: 5).first }
                report.line("链接卡 左缘（距卡片左缘）", [("来源图标", icon.map { $0.minX - card.minX }), ("图标方块", square.minX - card.minX), ("网址行", route.map { $0.minX - card.minX })], at: cardInset, tolerance: AuditReport.glyphTolerance)
            }
            canvas.crop(CGRect(x: card.minX - 8, y: card.minY - 8, width: card.width + 16, height: card.height + 16), "card\(index + 1)")
        }
        try canvas.write(to: output)
        try report.write(to: output.appendingPathComponent("report.md"))
        controller.hide()
    }

    // MARK: Rows

    /// One row's content: its filled container, when the row has one, and the runs inside it.
    private struct Row {
        var band: Box
        var container: Box?
        var parts: [Box]
        var bg: RGB
    }

    /// Splits `area` into rows, then each row into runs. A row whose left edge is filled top to bottom
    /// is a button or banner; its runs are measured against its own fill.
    private static func rows(_ canvas: AuditCanvas, in area: CGRect, outside: RGB, rowGap: Double = 2, gap: Double = 5) -> [Row] {
        canvas.segments(in: area, axis: .vertical, bg: outside, minDiff: 8, gap: rowGap).map { band in
            // A fill spans the whole band, so both of its ends are filled top to bottom.
            let left = band.minX + 1.5
            let right = band.maxX - 1.5
            let filled = [left, right].allSatisfy { x in
                [0.3, 0.5, 0.7].allSatisfy { canvas.color(at: CGPoint(x: x, y: band.minY + band.height * $0)).distance(to: outside) > 8 }
            }
            if filled, band.height >= 14 {
                let container = shape(canvas, row: CGPoint(x: left, y: band.midY), column: CGPoint(x: band.midX, y: band.midY), outside: outside)
                let fill = canvas.color(at: CGPoint(x: container.minX + 4, y: container.midY))
                // Inset past the rounded ends so the container's own hairline isn't content.
                let parts = canvas.segments(in: container.rect.insetBy(dx: 6, dy: 2), bg: fill, minDiff: 25, gap: gap)
                return Row(band: band, container: container, parts: parts, bg: fill)
            }
            let parts = canvas.segments(in: band.rect.insetBy(dx: -1, dy: -1), bg: outside, minDiff: 25, gap: gap)
            return Row(band: band, container: nil, parts: parts, bg: outside)
        }
    }

    private static func describe(_ rows: [Row], in report: AuditReport) {
        for (i, row) in rows.enumerated() {
            let parts = row.parts.map { String(format: "%.1f–%.1f", $0.minX, $0.maxX) }.joined(separator: "，")
            let box = row.container.map { String(format: "底 %.1f–%.1f × %.1f–%.1f；", $0.minX, $0.maxX, $0.minY, $0.maxY) } ?? ""
            report.info(String(format: "行 %d（y %.1f–%.1f）", i, row.band.minY, row.band.maxY), box + "内容 x " + parts)
        }
    }

    // MARK: Status menu

    @Test func statusMenu() async throws {
        guard let output = try Self.prepare() else { return }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "TroveAudit-\(UUID().uuidString)")!)
        let view = StatusMenuView(
            settings: settings, clipCount: 3, version: "1.3.0", accessibilityTrusted: false,
            clipboardAccessNeedsAction: true, shortcutRegistered: true, canCheckForUpdates: true,
            onShow: {}, onClearHistory: {}, onCheckUpdates: {}, onClose: {}, onGrantAccessibility: {},
            onAllowClipboardAccess: {}, onQuit: {}
        )
        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize
        let window = KeyablePanel(contentRect: NSRect(x: 300, y: 300, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(700))
        let content = try #require(window.contentView)
        Self.hideGlass(in: content)
        let canvas = AuditCanvas(name: "status-menu", view: content, backdrop: NSColor(Theme.Surface.coal))
        let report = Self.report
        let W = canvas.size.width
        let outside = canvas.backdrop
        report.section("状态菜单", String(format: "宽 %.0f，高 %.1f。行按从上到下编号。", W, canvas.size.height))
        let rows = Self.rows(canvas, in: CGRect(x: 3, y: 2, width: W - 6, height: canvas.size.height - 4), outside: outside)
        for row in rows {
            canvas.mark(row.container, .systemTeal)
            row.parts.forEach { canvas.mark($0) }
        }
        Self.describe(rows, in: report)

        // Rows with an icon at the left, top to bottom; hairlines are one point tall.
        let content_ = rows.filter { $0.band.height > 3 && !$0.parts.isEmpty }
        let header = content_.first
        let footer = content_.last
        let body = Array(content_.dropFirst().dropLast())
        let grid = StatusMenuView.Layout.self
        var icons: [(String, Double?)] = [("页头标志", header?.parts.first?.midX)]
        var texts: [(String, Double?)] = [("页头 Trove", header.flatMap { $0.parts.count > 1 ? $0.parts[1].minX : nil })]
        var rights: [(String, Double?)] = [("页头版本号", header?.parts.last.map { W - $0.maxX })]
        for (i, row) in body.enumerated() {
            let icon = row.parts.first
            let text = row.parts.count > 1 ? row.parts[1] : nil
            let label = "第 \(i + 1) 行"
            icons.append((label, icon?.midX))
            texts.append((label, text?.minX))
            if let text, let icon {
                let line = canvas.textLine(text, bg: row.bg)
                if text.height < 16 {
                    report.check("\(label) 图标中心 y（文字字身中线）", icon.midY, line.center, tolerance: AuditReport.glyphCenterTolerance)
                }
            }
            if let container = row.container {
                report.check("\(label) 内容 中线 y（底色中线）", row.parts.map { $0.midY }.reduce(0, +) / Double(max(1, row.parts.count)), container.midY, tolerance: 1)
            }
            if row.parts.count > 2, let last = row.parts.last {
                rights.append((label, W - last.maxX))
            }
        }
        rights.append(("页脚 退出", footer?.parts.last.map { W - $0.maxX }))
        report.line("左侧图标 中线 x", icons, at: grid.inset + grid.iconColumn / 2)
        report.line("文字起点 x", texts, at: grid.inset + grid.iconColumn + grid.iconGap, tolerance: AuditReport.glyphTolerance)
        report.line("右侧可见边（距菜单右缘）", rights, at: grid.inset, tolerance: AuditReport.glyphTolerance)
        report.check("页脚 左侧文字起点", footer?.parts.first?.minX, grid.inset, tolerance: AuditReport.glyphTolerance)
        // Hairlines: the header's and footer's run edge to edge; the separators between groups span
        // the content.
        for line in rows where line.band.height <= 3 {
            guard let ink = canvas.ink(in: CGRect(x: 1, y: line.band.minY - 0.5, width: W - 2, height: line.band.height + 1), bg: outside, minDiff: 4) else { continue }
            let name = String(format: "分隔线 y %.1f", line.band.midY)
            if ink.minX < 4 {
                report.info(name, "通栏")
            } else {
                report.line(name + " 两端（距菜单边）", [("左", ink.minX), ("右", W - ink.maxX)], at: grid.inset)
            }
        }
        if let header, let logo = header.parts.first {
            let fill = canvas.color(at: CGPoint(x: logo.minX + 2, y: logo.midY))
            let glyph = canvas.ink(in: logo.rect.insetBy(dx: 1.5, dy: 1.5), bg: fill, relative: 0.3)
            canvas.mark(glyph, .systemYellow)
            report.check("页头标志 字形中心 x", glyph?.midX, logo.midX)
            report.check("页头标志 字形中心 y", glyph?.midY, logo.midY)
        }
        let gaps = zip(rows, rows.dropFirst()).map { String(format: "%.1f", $1.band.minY - $0.band.maxY) }.joined(separator: "，")
        report.info("相邻行的可见间隔（从上到下）", gaps)
        canvas.crop(CGRect(x: 0, y: 0, width: W, height: canvas.size.height / 2), "top")
        canvas.crop(CGRect(x: 0, y: canvas.size.height / 2, width: W, height: canvas.size.height / 2), "bottom")
        try canvas.write(to: output)
        try report.write(to: output.appendingPathComponent("report.md"))
        window.orderOut(nil)
    }

    // MARK: Welcome

    @Test(arguments: [WelcomeController.Reason.firstLaunch, .pasteNeedsAccessibility])
    func welcome(_ reason: WelcomeController.Reason) async throws {
        guard let output = try Self.prepare() else { return }
        let settings = AppSettings(defaults: UserDefaults(suiteName: "TroveAudit-\(UUID().uuidString)")!)
        // The test process's own icon is a folder; with `TROVE_AUDIT_ICON` the window shows Trove's.
        let trove = ProcessInfo.processInfo.environment["TROVE_AUDIT_ICON"].flatMap(NSImage.init(contentsOfFile:))
        if let trove { NSApp.applicationIconImage = trove }
        let controller = WelcomeController(guide: PermissionGuide(), settings: settings)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        controller.show(reason)
        try await Task.sleep(for: .milliseconds(700))
        let window = try #require(NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible })
        let content = try #require(window.contentView)
        let name = reason == .firstLaunch ? "welcome-first" : "welcome-paste"
        let canvas = AuditCanvas(name: name, view: content, backdrop: NSColor(Theme.Surface.coal))
        let report = Self.report
        let W = canvas.size.width
        let outside = canvas.backdrop
        let grid = WelcomeView.Layout.self
        report.section(reason == .firstLaunch ? "欢迎窗口 · 首次启动" : "欢迎窗口 · 粘贴缺权限", String(format: "宽 %.0f，高 %.1f；内边距 %.0f。", W, canvas.size.height, grid.inset) + (trove == nil ? "没有设 TROVE_AUDIT_ICON，页头是测试进程的文件夹图标，不量它的上边。" : ""))
        let rows = Self.rows(canvas, in: CGRect(x: 2, y: 2, width: W - 4, height: canvas.size.height - 4), outside: outside, rowGap: 3, gap: 6)
        for row in rows {
            canvas.mark(row.container, .systemTeal)
            row.parts.forEach { canvas.mark($0) }
        }
        Self.describe(rows, in: report)
        if let icon = rows.first?.parts.first {
            report.check("页头图标 中心 x（窗口中线）", icon.midX, W / 2)
        }
        for (i, row) in rows.enumerated() where row.parts.count == 1 && row.container == nil && i > 0 && i < 3 {
            report.check("第 \(i) 行文字 中心 x（窗口中线）", row.parts[0].midX, W / 2)
        }
        let gaps = zip(rows, rows.dropFirst()).map { String(format: "%.1f", $1.band.minY - $0.band.maxY) }.joined(separator: "，")
        report.info("相邻行的可见间隔（从上到下）", gaps)
        if trove != nil {
            // The view starts under the transparent title bar.
            let titleBar = window.frame.height - window.contentLayoutRect.height
            report.check("图标 顶（标题栏下）", rows.first.map { $0.band.minY - titleBar }, grid.top)
        }
        report.check("底部留白", rows.last.map { canvas.size.height - $0.band.maxY }, grid.inset)

        // Feature rows (first launch): an accent tile with a glyph, then a title and a detail line.
        let features = rows.filter { $0.container == nil && $0.parts.count >= 2 && ($0.parts.first?.width ?? 0) > 26 && ($0.parts.first?.width ?? 0) < 34 }
        var featureIcons: [(String, Double?)] = []
        var featureTexts: [(String, Double?)] = []
        for (i, row) in features.enumerated() {
            let tile = row.parts[0]
            let fill = canvas.color(at: CGPoint(x: tile.minX + 3, y: tile.midY))
            let glyph = canvas.ink(in: tile.rect.insetBy(dx: 2, dy: 2), bg: fill, relative: 0.35)
            canvas.mark(glyph, .systemYellow)
            report.check("用法 \(i + 1) 图标字形中心 x（方块中心）", glyph?.midX, tile.midX)
            report.check("用法 \(i + 1) 图标字形中心 y（方块中心）", glyph?.midY, tile.midY)
            featureIcons.append(("用法 \(i + 1)", tile.minX))
            featureTexts.append(("用法 \(i + 1)", row.parts[1].minX))
            let firstLine = canvas.segments(in: row.parts[1].rect.insetBy(dx: -1, dy: -1), axis: .vertical, bg: outside, minDiff: 25, gap: 1.5).first
            if let firstLine {
                report.info("用法 \(i + 1) 标题行与方块", String(format: "标题字身中线 %.1f，方块中心 %.1f，方块顶 %.1f，标题顶 %.1f", canvas.textLine(firstLine, bg: outside).center, tile.midY, tile.minY, firstLine.minY))
            }
        }

        // The permission card.
        if let card = rows.compactMap(\.container).max(by: { $0.width < $1.width }) {
            report.check("权限卡片 左", card.minX, grid.inset)
            report.check("权限卡片 右", W - card.maxX, grid.inset)
            // Rows in the view's order; a granted one shows "Allowed" where the button would be.
            let granted = [AccessibilityPermission.isTrusted, ClipboardAccessPermission.isAllowed]
            let cardFill = canvas.color(at: CGPoint(x: card.minX + 4, y: card.midY))
            let cardRows = Self.rows(canvas, in: card.rect.insetBy(dx: 3, dy: 3), outside: cardFill, rowGap: 6, gap: 6)
            var permIcons: [(String, Double?)] = []
            var permTexts: [(String, Double?)] = []
            for (i, row) in cardRows.filter({ $0.band.height > 3 && $0.parts.count >= 2 }).enumerated() {
                row.parts.forEach { canvas.mark($0, .systemOrange) }
                permIcons.append(("权限 \(i + 1)", row.parts[0].midX))
                permTexts.append(("权限 \(i + 1)", row.parts[1].minX))
                // A text block's ink center moves with its descenders, by up to a glyph's bearing.
                report.check("权限 \(i + 1) 图标中心 y（文字块中线）", row.parts[0].midY, row.parts[1].midY, tolerance: AuditReport.glyphTolerance)
                if i < granted.count, granted[i], let label = row.parts.last {
                    report.check("权限 \(i + 1) 已允许 右距卡片", card.maxX - label.maxX, grid.cardPadding, tolerance: AuditReport.glyphTolerance)
                } else if let button = row.parts.last, row.parts.count >= 3 {
                    report.check("权限 \(i + 1) 按钮 右距卡片", card.maxX - button.maxX, grid.cardPadding)
                    let buttonBox = Self.shape(canvas, row: CGPoint(x: button.minX + 2, y: button.midY), column: CGPoint(x: button.midX, y: button.minY + 2), outside: cardFill)
                    let fill = canvas.color(at: CGPoint(x: buttonBox.minX + 3, y: buttonBox.midY))
                    let label = canvas.ink(in: buttonBox.rect.insetBy(dx: 2, dy: 2), bg: fill, relative: 0.4)
                    canvas.mark(label, .systemYellow)
                    report.check("权限 \(i + 1) 按钮文字 中心 x", label?.midX, buttonBox.midX, tolerance: AuditReport.glyphCenterTolerance)
                    report.check("权限 \(i + 1) 按钮文字 字身中线 y", label.map { canvas.textLine($0, bg: fill).center }, buttonBox.midY)
                }
            }
            report.line("权限行 图标中线 x", permIcons, at: grid.inset + grid.cardPadding + grid.permissionIcon / 2)
            report.line("文字起点：用法 / 权限", featureTexts + permTexts, at: grid.inset + grid.tile + grid.iconGap, tolerance: AuditReport.glyphTolerance)
            if !featureIcons.isEmpty {
                report.line("左缘：用法方块 / 权限卡片", featureIcons + [("权限卡片", card.minX)], at: grid.inset)
            }
        }
        if let button = rows.last, let face = button.container {
            report.check("底部按钮 右", W - face.maxX, grid.inset)
            if let label = button.parts.first {
                report.check("底部按钮文字 中心 x", label.midX, face.midX, tolerance: AuditReport.glyphCenterTolerance)
            }
        }
        canvas.crop(CGRect(x: 0, y: 0, width: W, height: min(canvas.size.height, 260)), "top")
        canvas.crop(CGRect(x: 0, y: max(0, canvas.size.height - 260), width: W, height: min(canvas.size.height, 260)), "bottom")
        try canvas.write(to: output)
        try report.write(to: output.appendingPathComponent("report.md"))
        window.close()
    }

    // MARK: Empty panel and peek

    @Test func emptyPanelAndPeek() async throws {
        guard let output = try Self.prepare() else { return }
        let report = Self.report
        do {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = ClipStore(files: ClipFiles(root: root))
            let pasteboard = NSPasteboard.withUniqueName()
            let controller = PanelController(store: store, pasteboard: ClipPasteboard(store: store, monitor: ClipboardMonitor(store: store, pasteboard: pasteboard), pasteboard: pasteboard))
            controller.show(on: Self.retinaScreen)
            try await Task.sleep(for: .milliseconds(900))
            let window = try #require(NSApp.windows.first { $0.isVisible && $0 is PanelWindow })
            let content = try #require(window.contentView)
            Self.hideGlass(in: content)
            let canvas = AuditCanvas(name: "panel-empty", view: content, backdrop: NSColor(Theme.Surface.coal))
            let area = CGRect(x: 4, y: PanelLayout.inset + PanelLayout.toolbarHeight + 2, width: canvas.size.width - 8, height: canvas.size.height - PanelLayout.inset - PanelLayout.toolbarHeight - 6)
            let group = canvas.ink(in: area, minDiff: 20)
            canvas.mark(group)
            report.section("面板 · 空状态")
            let timelineTop = PanelLayout.inset + PanelLayout.toolbarHeight
            report.check("图标与文字整体 中心 x", group?.midX, canvas.size.width / 2)
            report.check("图标与文字整体 中心 y（工具栏以下区域的中线）", group?.midY, (timelineTop + canvas.size.height) / 2)
            report.info("整体", String(format: "y %.1f–%.1f", group?.minY ?? 0, group?.maxY ?? 0))
            canvas.crop(CGRect(x: canvas.size.width / 2 - 200, y: 0, width: 400, height: canvas.size.height), "center")
            try canvas.write(to: output)
            controller.hide()
        }
        do {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = Self.sampleStore(root: root)
            store.add(text: String(repeating: "A long first line that runs the full width of the bubble ", count: 6), sourceApp: "Finder")
            let pasteboard = NSPasteboard.withUniqueName()
            let controller = PanelController(store: store, pasteboard: ClipPasteboard(store: store, monitor: ClipboardMonitor(store: store, pasteboard: pasteboard), pasteboard: pasteboard))
            controller.show(on: Self.retinaScreen)
            try await Task.sleep(for: .milliseconds(600))
            let panel = try #require(NSApp.windows.first { $0.isVisible && $0 is PanelWindow })
            _ = controller.handleKey(.space, [])
            try await Task.sleep(for: .milliseconds(700))
            // On black: the bubble's dark shadow then can't pass for part of the bubble.
            let peek = PeekController.self
            report.section("预览气泡（空格）", String(format: "内边距 %.0f，提示列宽 %.0f、与内容相隔 %.0f。", peek.contentInset, peek.hintWidth, peek.hintGap))
            /// The bubble, its text and its hint; the hint has its own column at the top-right.
            func measure(_ canvas: AuditCanvas, _ name: String) -> (bubble: Box, text: Box?, hint: Box?, lines: [Box], fill: RGB) {
                let margin = peek.shadowMargin
                let bubble = Self.shape(canvas, row: CGPoint(x: margin + 3, y: margin + 24), column: CGPoint(x: canvas.size.width / 2, y: margin + 3), outside: canvas.backdrop)
                canvas.mark(bubble, .systemTeal)
                let fill = canvas.color(at: CGPoint(x: bubble.minX + 4, y: bubble.minY + 24))
                // Regions kept clear of the rounded corners, whose edge line would read as content.
                let column = bubble.maxX - peek.contentInset - peek.hintWidth - peek.hintGap / 2
                let body = CGRect(x: bubble.minX + 10, y: bubble.minY + 3, width: column - bubble.minX - 10, height: bubble.height - peek.tailHeight - 6)
                let lines = canvas.segments(in: body, axis: .vertical, bg: fill, minDiff: 25, gap: 2)
                let text = canvas.ink(in: body, bg: fill, minDiff: 25)
                let hint = canvas.ink(in: CGRect(x: column, y: bubble.minY + 8, width: bubble.maxX - 6 - column, height: peek.contentInset + peek.lineHeight - 4), bg: fill, minDiff: 25)
                canvas.mark(text)
                canvas.mark(hint, .systemYellow)
                report.info("\(name) 气泡", String(format: "%.1f×%.1f，%d 行", bubble.width, bubble.height, lines.count))
                report.line("\(name) 文字左边距 / 提示右边距（可见）", [("文字", text.map { $0.minX - bubble.minX }), ("提示", hint.map { bubble.maxX - $0.maxX })], tolerance: AuditReport.glyphTolerance)
                if let first = lines.first {
                    report.check("\(name) 提示 中心 y（首行字身中线）", hint?.midY, canvas.textLine(first, bg: fill).center)
                }
                return (bubble, text, hint, lines, fill)
            }
            if let long = NSApp.windows.first(where: { $0.isVisible && $0 is NSPanel && $0 !== panel && $0.frame.minY >= panel.frame.maxY - 30 }) {
                let canvas = AuditCanvas(name: "peek-long", view: try #require(long.contentView), backdrop: .black)
                let m = measure(canvas, "长文字")
                // The text column ends where the hint column begins.
                report.check("长文字 文字右缘到提示列", m.text.map { m.bubble.maxX - peek.contentInset - peek.hintWidth - peek.hintGap - $0.maxX }, 0, tolerance: 6)
                canvas.crop(CGRect(x: canvas.size.width - 160, y: 0, width: 160, height: 70), "corner")
                try canvas.write(to: output)
            }
            _ = controller.handleKey(.space, [])
            _ = controller.handleKey(.rightArrow, [])
            try await Task.sleep(for: .milliseconds(300))
            _ = controller.handleKey(.space, [])
            try await Task.sleep(for: .milliseconds(700))
            let window = try #require(NSApp.windows.first { $0.isVisible && $0 is NSPanel && $0 !== panel && $0.frame.minY >= panel.frame.maxY - 30 })
            let canvas = AuditCanvas(name: "peek", view: try #require(window.contentView), backdrop: .black)
            let m = measure(canvas, "单行")
            if let first = m.lines.first {
                // One line: the space above the letters and below the baseline should match.
                let line = canvas.textLine(first, bg: m.fill)
                let bodyBottom = m.bubble.maxY - peek.tailHeight
                report.check("单行 文字字身中线 y（气泡主体中线）", line.center, (m.bubble.minY + bodyBottom) / 2, tolerance: 1)
            }
            try canvas.write(to: output)
            try report.write(to: output.appendingPathComponent("report.md"))
            controller.hide()
        }
    }

    // MARK: Glass

    /// Tern's window glass at its default settings (Clear material, 60% opacity, anthracite), measured
    /// the same way over white, gray and black on 2026-11-23. The panel's glass should look the same.
    private static let ternWindowGlass: [String: RGB] = [
        "白": RGB(r: 0x47, g: 0x48, b: 0x4C), "中灰": RGB(r: 0x2F, g: 0x31, b: 0x36), "黑": RGB(r: 0x13, g: 0x15, b: 0x1B)
    ]

    /// The real glass over a white, a mid-gray and a black desktop. Each window shows above a plain
    /// window of that color and the screen is captured with `screencapture`, so the window server's blur
    /// is in the picture (an off-screen render draws the material as flat gray). The glass is read in an
    /// empty stretch, and the text tiers are checked against it (WCAG contrast).
    @Test func glass() async throws {
        guard let output = try Self.prepare() else { return }
        let report = Self.report
        report.section("玻璃", "真实屏幕截图：窗口放在纯色窗口前，读空白处的玻璃颜色，按 WCAG 算各级文字的对比度。面板对标 Tern 的窗口玻璃，状态菜单对标 Tern 的菜单玻璃。")
        let screenHeight = try #require(NSScreen.screens.first).frame.height
        let backdrops = [("白", NSColor.white), ("中灰", NSColor(white: 0.5, alpha: 1)), ("黑", NSColor.black)]

        /// Shows each backdrop under `window`, photographs `area` (window points, top-left origin) and
        /// returns the glass color read in `probe` (same coordinates).
        func photograph(_ window: NSWindow, _ name: String, area: CGRect, probe: CGRect) async throws -> [(String, RGB)] {
            var colors: [(String, RGB)] = []
            for (backdropName, color) in backdrops {
                let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -60, dy: -60), styleMask: .borderless, backing: .buffered, defer: false)
                backdrop.backgroundColor = color
                backdrop.level = NSWindow.Level(rawValue: window.level.rawValue - 1)
                backdrop.orderFront(nil)
                try await Task.sleep(for: .milliseconds(600))
                let screenArea = CGRect(x: window.frame.minX + area.minX, y: screenHeight - window.frame.maxY + area.minY, width: area.width, height: area.height)
                let file = output.appendingPathComponent("glass-\(name)-\(backdropName).png")
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-R\(Int(screenArea.minX)),\(Int(screenArea.minY)),\(Int(screenArea.width)),\(Int(screenArea.height))", file.path]
                try capture.run()
                capture.waitUntilExit()
                backdrop.orderOut(nil)
                let image = try #require(NSImage(contentsOf: file))
                let canvas = AuditCanvas(name: "glass-read", image: image, size: area.size, backdrop: .black)
                colors.append((backdropName, canvas.background(of: probe.offsetBy(dx: -area.minX, dy: -area.minY))))
            }
            return colors
        }
        let t1 = RGB(NSColor(Theme.Text.t1)), t2 = RGB(NSColor(Theme.Text.t2)), t3 = RGB(NSColor(Theme.Text.t3))

        // The panel: window glass. Read right of the reset button, left of the search field.
        do {
            let root = makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let store = Self.sampleStore(root: root)
            let pasteboard = NSPasteboard.withUniqueName()
            let controller = PanelController(store: store, pasteboard: ClipPasteboard(store: store, monitor: ClipboardMonitor(store: store, pasteboard: pasteboard), pasteboard: pasteboard))
            controller.show(on: Self.retinaScreen)
            try await Task.sleep(for: .milliseconds(900))
            let panel = try #require(NSApp.windows.first { $0.isVisible && $0 is PanelWindow })
            let inset = PanelLayout.inset
            let probe = CGRect(x: inset + PanelLayout.toolbarHeight + 24, y: inset + 4, width: 80, height: PanelLayout.toolbarHeight - 8)
            let area = CGRect(x: 0, y: 0, width: panel.frame.width, height: 160)
            // The second card (not selected), in its meta row between the name and the time.
            let metrics = CardMetrics(size: .init(screenHeight: panel.screen?.frame.height ?? 0))
            let second = inset + metrics.width + inset
            let cardTop = inset * 2 + PanelLayout.toolbarHeight
            let cardProbe = CGRect(x: second + metrics.width * 0.4, y: cardTop + metrics.metaSpace + 2, width: metrics.width * 0.2, height: metrics.iconSize - 4)
            let cards = try await photograph(panel, "面板卡片", area: area, probe: cardProbe)
            for (backdrop, card) in cards {
                report.info("卡片 \(backdrop)色桌面前的底色", card.hex)
                report.atLeast("卡片 \(backdrop)色桌面 t1 对比度（名称、正文）", t1.contrast(with: card), 4.5)
                // The glass card's accepted cost (ADR 0019): over a white desktop the time reads at about
                // 2.8:1. The floor catches it getting fainter still.
                report.atLeast("卡片 \(backdrop)色桌面 t2 对比度（时间）", t2.contrast(with: card), 2.5)
            }
            for (backdrop, glass) in try await photograph(panel, "面板", area: area, probe: probe) {
                let tern = try #require(Self.ternWindowGlass[backdrop])
                report.check("面板 \(backdrop)色桌面前 与 Tern 窗口玻璃的色差", glass.distance(to: tern), 0, tolerance: 8)
                report.info("面板 \(backdrop)色桌面前的玻璃", "\(glass.hex)（Tern \(tern.hex)），t3 对比度 \(String(format: "%.1f", t3.contrast(with: glass)))")
                report.atLeast("面板 \(backdrop)色桌面 t1 对比度", t1.contrast(with: glass), 4.5)
                // As Tern's window glass: secondary text keeps 3:1 over a white desktop, not 4.5.
                report.atLeast("面板 \(backdrop)色桌面 t2 对比度", t2.contrast(with: glass), 3)
            }
            controller.hide()
        }

        // The status menu: menu glass. Read in the header, between the clip count and the version.
        do {
            let settings = AppSettings(defaults: UserDefaults(suiteName: "TroveAudit-\(UUID().uuidString)")!)
            let view = StatusMenuView(
                settings: settings, clipCount: 3, version: "1.3.0", accessibilityTrusted: true,
                clipboardAccessNeedsAction: false, shortcutRegistered: true, canCheckForUpdates: true,
                onShow: {}, onClearHistory: {}, onCheckUpdates: {}, onClose: {}, onGrantAccessibility: {},
                onAllowClipboardAccess: {}, onQuit: {}
            )
            let hosting = NSHostingController(rootView: view)
            let size = hosting.view.fittingSize
            let menu = KeyablePanel(contentRect: NSRect(x: 300, y: 300, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            menu.contentViewController = hosting
            menu.isOpaque = false
            menu.backgroundColor = .clear
            menu.level = .popUpMenu
            // A panel hides while its app is inactive, and the test process never is active.
            menu.hidesOnDeactivate = false
            menu.orderFront(nil)
            try await Task.sleep(for: .milliseconds(700))
            let probe = CGRect(x: 130, y: 16, width: 90, height: 20)
            for (backdrop, glass) in try await photograph(menu, "状态菜单", area: CGRect(origin: .zero, size: size), probe: probe) {
                report.info("状态菜单 \(backdrop)色桌面前的玻璃", glass.hex)
                report.atLeast("状态菜单 \(backdrop)色桌面 t1 对比度", t1.contrast(with: glass), 4.5)
                report.atLeast("状态菜单 \(backdrop)色桌面 t2 对比度", t2.contrast(with: glass), 4.5)
                report.atLeast("状态菜单 \(backdrop)色桌面 t3 对比度", t3.contrast(with: glass), 3)
            }
            menu.orderOut(nil)
        }
        try report.write(to: output.appendingPathComponent("report.md"))
    }

    // MARK: App icon

    /// `TROVE_AUDIT_ICON` points at an `.icns` made by `scripts/generate-app-icon.swift`.
    @Test func appIcon() throws {
        guard let output = try Self.prepare(), let path = ProcessInfo.processInfo.environment["TROVE_AUDIT_ICON"] else { return }
        let image = try #require(NSImage(contentsOfFile: path))
        let canvas = AuditCanvas(name: "app-icon", image: image, size: CGSize(width: 512, height: 512), backdrop: NSColor(Theme.Surface.coal))
        let report = Self.report
        report.section("应用图标（1024 画布，单位换算成 512pt）", "macOS 图标网格：圆角方形 824/1024，四边各留 100/1024，即 512pt 画布上 412pt、四边各 50pt。")
        let base = canvas.ink(in: CGRect(x: 0, y: 0, width: 512, height: 512), minDiff: 60, relative: 0.5)
        canvas.mark(base, .systemTeal)
        report.check("底板 宽", base?.width, 412)
        report.check("底板 中心 x", base?.midX, 256)
        report.check("底板 中心 y", base?.midY, 256)
        if let base {
            let white = canvas.color(at: CGPoint(x: base.midX, y: base.minY + 12))
            // Only inside the plate, 8pt clear of its rounded edge. The corners are continuous, which
            // reach further in than a circular arc of the same radius (185.4/1024), so the mask uses a
            // larger one.
            let radius = 230.0 / 1024 * 512 - 8
            let plate = base.rect.insetBy(dx: 8, dy: 8)
            let inside: (CGPoint) -> Bool = { p in
                let cx = min(max(p.x, plate.minX + radius), plate.maxX - radius)
                let cy = min(max(p.y, plate.minY + radius), plate.maxY - radius)
                return hypot(p.x - cx, p.y - cy) <= radius && plate.contains(p)
            }
            let art = canvas.ink(in: plate, bg: white, within: inside, minDiff: 40, relative: 0.3)
            canvas.mark(art)
            report.check("画面外框 中心 x（底板中心）", art?.midX, base.midX)
            report.check("画面外框 中心 y（底板中心）", art?.midY, base.midY)
            report.info("画面 到底板四边", String(format: "左 %.1f，右 %.1f，上 %.1f，下 %.1f", (art?.minX ?? 0) - base.minX, base.maxX - (art?.maxX ?? 0), (art?.minY ?? 0) - base.minY, base.maxY - (art?.maxY ?? 0)))
        }
        try canvas.write(to: output)
        try report.write(to: output.appendingPathComponent("report.md"))
    }
}
