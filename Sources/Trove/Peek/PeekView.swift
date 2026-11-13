import SwiftUI

/// Presentation counter the controller bumps on each show so the bubble view replays its entrance.
@MainActor
final class PeekPopState: ObservableObject {
    @Published var generation = 0
}

/// The bubble's SwiftUI content: the selected clip in a rounded card with a tail. The controller
/// closes the bubble on any selection change, so it only ever shows the card it was opened on.
struct PeekView: View {
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
