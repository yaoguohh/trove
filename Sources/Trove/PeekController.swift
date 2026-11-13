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

/// Presentation counter the controller bumps on each show so the bubble view replays its entrance.
@MainActor
final class PeekPopState: ObservableObject {
    @Published var generation = 0
}

/// The bubble's SwiftUI content: the selected clip in a rounded card with a tail. The controller
/// closes the bubble on any selection change, so it only ever shows the card it was opened on.
private struct PeekView: View {
    @Environment(\.clipFiles) private var files
    @ObservedObject var model: PanelViewModel
    @ObservedObject var pop: PeekPopState
    let expand: (Clip) -> Void

    var body: some View {
        Group {
            if let item = model.selectedItem {
                bubble(for: item)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clear gutter around the bubble so the drop shadow has room (window is borderless/clear).
        .padding(PeekController.shadowMargin)
    }

    private func bubble(for item: Clip) -> some View {
        let tail = PeekController.tailHeight
        return ZStack {
            BubbleTailShape(tailHeight: tail).fill(Theme.Surface.card)
            BubbleTailShape(tailHeight: tail).stroke(Theme.Line.l2, lineWidth: 1)
            content(for: item)
                .padding(PeekController.contentInset)
                .padding(.bottom, tail) // keep content clear of the tail notch
        }
        .compositingGroup()
        .shadow(Theme.Shadow.floating)
        .popIn(trigger: pop.generation, nudge: 3)
        // A tiny, non-interactive hint that the peek is expandable (↗ opens a URL in the browser, ⤢
        // opens the inspector) — small and tertiary so it never dominates the bubble.
        .overlay(alignment: .topTrailing) { expandHint(item) }
        // The WHOLE bubble is the expand affordance: a clear overlay button (the proven click path in
        // this non-activating panel) so a tap anywhere opens the inspector, with no bulky control.
        .overlay {
            Button { expand(item) } label: { Color.clear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help(String(localized: "Open Full Preview"))
        }
    }

    /// A small ↗/⤢ glyph hinting the peek is clickable-to-expand. ↗ for a single URL (opens the
    /// browser), the in-place expand glyph otherwise (opens the inspector) — mirroring what the
    /// tap will actually do via `PanelController.showInspector`.
    private func expandHint(_ item: Clip) -> some View {
        let opensInBrowser: Bool
        if case .openURL = InspectorRenderer.expandAction(for: item.text, kind: item.kind) {
            opensInBrowser = true
        } else {
            opensInBrowser = false
        }
        return Image(systemName: opensInBrowser ? "arrow.up.right" : "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.Text.t3)
            .padding(9)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func content(for item: Clip) -> some View {
        if item.kind == .image, let image = ImageCache.image(for: item, in: files) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if item.kind == .image {
            ImageUnavailableView(symbolSize: 30, textSize: 12)
        } else {
            Text(item.text.prefix(PeekController.bubbleTextCap))
                .font(.system(size: 13))
                .foregroundStyle(Theme.Text.t1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
        }
    }

}

/// A rounded-rectangle bubble with a Dock-tooltip-style tail at its bottom-center, traced as ONE
/// continuous outline. The macOS Dock label tail is drawn privately (no public API; NSPopover is the
/// only system "bubble with arrow" but it steals key focus, which would break the panel's keyboard
/// model) — so we replicate the look: the bottom edge flows into the tail through a smooth ogee
/// (the base junctions are tangent to the bottom edge → a soft concave fillet, not a hard triangle),
/// narrowing to a soft point. One path means fill and stroke share a seamless silhouette (no seam).
struct BubbleTailShape: Shape {
    var cornerRadius: CGFloat = Theme.Radius.panel
    var tailWidth: CGFloat = 26
    var tailHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height - tailHeight) / 2)
        let bottom = rect.maxY - tailHeight   // the body's bottom edge = the tail's base
        let tip = rect.maxY
        let midX = rect.midX
        let half = tailWidth / 2

        var path = Path()
        // Top edge + rounded top corners.
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        // Right edge down to the bottom-right corner.
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        // Bottom edge → ogee tail → soft point → back out. control1 sits ON the bottom edge so the
        // curve leaves the base horizontally (a tangent fillet that merges into the body); control2
        // partway down the side gives a soft, non-blunt tip.
        path.addLine(to: CGPoint(x: midX + half, y: bottom))
        path.addCurve(
            to: CGPoint(x: midX, y: tip),
            control1: CGPoint(x: midX + half * 0.45, y: bottom),
            control2: CGPoint(x: midX + half * 0.22, y: bottom + tailHeight * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: midX - half, y: bottom),
            control1: CGPoint(x: midX - half * 0.22, y: bottom + tailHeight * 0.55),
            control2: CGPoint(x: midX - half * 0.45, y: bottom)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - r), control: CGPoint(x: rect.minX, y: bottom))
        // Left edge up + rounded top-left corner.
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
