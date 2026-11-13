import AppKit
import SwiftUI

/// A Finder-Quick-Look-style peek: pressing Space over the selected card pops a small bubble
/// card ABOVE the panel — a rounded card with a little downward tail pointing at the panel —
/// showing the item at a glance (image scaled to fit, or a text excerpt). It floats in its own
/// borderless, NON-activating panel: clicking it doesn't make it key, so the main panel keeps focus
/// (the search field and the controller's key monitor keep working while the bubble is up). A click
/// anywhere on the bubble hands off to the full-size inspector (InspectorController).
@MainActor
final class PeekController {
    private let files: ClipFiles
    private var window: NSPanel?
    /// Bumped on every present so the (persistent) bubble view replays its popIn.
    private let popState = PeekPopState()
    /// Invoked when the bubble is clicked — opens the inspector for the peeked item.
    /// Wired by PanelController.
    var onExpand: ((Clip) -> Void)?

    /// Transparent margin baked into the window around the bubble so the drop shadow (drawn in
    /// SwiftUI, following the bubble+tail outline) has room to render instead of being clipped.
    static let shadowMargin: CGFloat = 20
    /// Height of the downward tail (the "小角") at the bubble's bottom-center. Kept small and soft
    /// so it reads as a gentle pointer, not a chunky triangle.
    static let tailHeight: CGFloat = 8
    /// Padding between the bubble's edge and its content. Shared with PeekView so the
    /// computed window size and the rendered content stay in lockstep.
    static let contentInset: CGFloat = 14
    /// Gap between the tail tip and the panel's top edge.
    static let gap: CGFloat = 6

    init(files: ClipFiles) {
        self.files = files
    }
    /// Max characters the peek bubble measures and renders. The bubble is a transient glance — the
    /// full content lives in the inspector — so capping both the `boundingRect` measure and the
    /// `Text` layout keeps a multi-MB clip from being laid out just to peek at its first lines.
    static let bubbleTextCap = 4_000

    var isVisible: Bool { window?.isVisible == true }

    /// Space toggles the peek for the current selection.
    func toggle(model: PanelViewModel, over panel: NSWindow) {
        if isVisible {
            hide()
        } else {
            present(model: model, over: panel)
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    /// The bubble was clicked: dismiss the peek and hand off to the inspector.
    private func expandTapped(_ item: Clip) {
        let action = onExpand
        hide()
        action?(item)
    }

    /// Shown only while hidden (`toggle`); any selection change hides the bubble instead of moving it.
    private func present(model: PanelViewModel, over panel: NSWindow) {
        // Nothing selected (empty results) → there's nothing to peek.
        guard let item = model.selectedItem else { hide(); return }
        if window == nil { createWindow(model: model) }
        guard let window else { return }

        window.setFrame(frame(for: item, over: panel), display: false)
        window.alphaValue = 0
        window.orderFront(nil)
        // Tern's popIn: the window fades while the bubble content scales up and rises 3pt — see
        // PeekView.
        popState.generation &+= 1
        window.fadeIn()
    }

    private func createWindow(model: PanelViewModel) {
        let hosting = NSHostingController(
            rootView: PeekView(model: model, pop: popState, expand: { [weak self] item in
                self?.expandTapped(item)
            })
            .environment(\.clipFiles, files)
        )
        hosting.sizingOptions = []
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            // .nonactivatingPanel + becomesKeyOnlyIfNeeded: the bubble accepts a click without
            // becoming key, so the main panel keeps focus and its key monitor keeps receiving keyDowns
            // while the peek is up.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the shadow is drawn in SwiftUI so it follows the bubble outline
        // One level above the main panel (also .floating) so the bubble is always on top of it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        // Mouse-enabled (the bubble is clickable) but never steals key from the main panel.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        self.window = panel
    }

    /// Center the bubble horizontally on the panel with its tail tip sitting just above the panel's
    /// top edge; size it adaptively to the space ABOVE the panel and clamp to the screen.
    private func frame(for item: Clip, over panel: NSWindow) -> NSRect {
        let margin = Self.shadowMargin
        let panelFrame = panel.frame
        let visible = panel.screen?.visibleFrame ?? panelFrame

        // Largest bubble (content + insets + tail) that fits in the gap above the panel and isn't
        // too wide; the window then adds `margin` on every side for the drop shadow.
        let topInset: CGFloat = 12
        let maxBubbleH = max(150, visible.maxY - topInset - panelFrame.maxY - Self.gap - margin)
        let maxBubbleW = max(240, min(visible.width * 0.70, visible.width - 8 - margin * 2))
        let maxContentW = maxBubbleW - Self.contentInset * 2
        let maxContentH = maxBubbleH - Self.contentInset * 2 - Self.tailHeight

        let content = Self.bubbleSize(for: item, files: files, maxContentW: maxContentW, maxContentH: maxContentH)
        let winW = content.width + margin * 2
        let winH = content.height + margin * 2

        var x = panelFrame.midX - winW / 2
        x = min(max(x, visible.minX + 4), visible.maxX - winW - 4)

        // The tail tip is `margin` above the window's bottom edge, and should land `gap` above the
        // panel's top edge → window bottom = panelTop + gap - margin.
        var y = panelFrame.maxY + Self.gap - margin
        if y + winH > visible.maxY - 4 { y = visible.maxY - 4 - winH }

        return NSRect(x: x.rounded(), y: y.rounded(), width: winW.rounded(), height: winH.rounded())
    }

    /// Snug size of the bubble body (including the tail), excluding the shadow margin. Scales the
    /// content up to the given caps (images aspect-fit, never upscaled past 1:1); mirrors the
    /// padding used in `PeekView` so the rendered content fills it exactly.
    static func bubbleSize(for item: Clip, files: ClipFiles, maxContentW: CGFloat, maxContentH: CGFloat) -> NSSize {
        let inset = contentInset
        func wrap(_ w: CGFloat, _ h: CGFloat) -> NSSize {
            NSSize(width: w + inset * 2, height: h + inset * 2 + tailHeight)
        }

        if item.kind == .image {
            if let image = ImageCache.image(for: item, in: files), image.size.width > 0, image.size.height > 0 {
                let fitted = ImageFit.size(
                    of: image.size,
                    within: CGSize(width: maxContentW, height: maxContentH),
                    atLeast: CGSize(width: 200, height: 130)
                )
                return wrap(fitted.width, fitted.height)
            }
            // Image kind but the backing file is gone → size for the "Image unavailable" placeholder
            // (rendered in PeekView), not for the empty text, so it isn't clipped.
            return wrap(min(180, maxContentW), min(72, maxContentH))
        }

        let cw = min(maxContentW, 432)
        let raw = item.text.isEmpty ? item.kind.title : String(item.text.prefix(bubbleTextCap))
        let measured = (raw as NSString).boundingRect(
            with: NSSize(width: cw, height: 6000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)]
        ).height
        let ch = max(30, min(ceil(measured), maxContentH))
        return wrap(cw, ch)
    }
}
