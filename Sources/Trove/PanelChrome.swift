import AppKit

/// The main panel's window class and glass backdrop, kept apart from `ClipboardPanelController`
/// (which is about showing, hiding and routing keys).
enum PanelChrome {
    /// A clear container holding the dense dark glass behind `content`, both pinned edge-to-edge.
    ///
    /// The glass HIDES background text the way the Dock does. The blur radius is ~constant across
    /// materials; what smears text into an unreadable wash is the material's baked-in fill density,
    /// so this uses the DENSEST dark material, `.hudWindow`, not the thin `.underWindowBackground`
    /// (which let background text read through). Full opacity is intentional: translucency must come
    /// from the material's heavy BLUR, not from alpha — lowering alpha lets the raw, un-blurred desktop
    /// bleed through and background window text becomes legible. The mask image clips the live blur
    /// to the rounded rect cleanly (`cornerRadius` + `masksToBounds` leaves faint fringing).
    @MainActor
    static func makeGlassContainer(content: NSView, cornerRadius: CGFloat) -> NSView {
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let glass = NSVisualEffectView(frame: .zero)
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        // Denser, more saturated variant — extra text suppression at no transparency cost.
        glass.isEmphasized = true
        glass.alphaValue = 1.0
        glass.wantsLayer = true
        glass.maskImage = .roundedMask(cornerRadius: cornerRadius)
        glass.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(glass)
        container.addSubview(content)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
}

/// A borderless panel that can still become key so the hosted SwiftUI search field receives text;
/// navigation/action keys are intercepted by the controller's window-level event monitor.
final class TrovePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // No main-menu Edit menu (menu-bar app), so route ⌘C/⌘X/⌘V/⌘A into the search field here. Only a
    // bare ⌘+letter is taken, so ⌘←/⌘→/⌘⌫/⌘Z still reach `handleKey`'s keyboard model. See
    // `EditingShortcuts`.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditingShortcuts.route(event) || super.performKeyEquivalent(with: event)
    }
}

extension NSImage {
    /// A black rounded-rect mask whose corners are protected by cap insets, so assigning it to
    /// `NSVisualEffectView.maskImage` (resizingMode `.stretch`) rounds the blur at any panel
    /// size without distorting the corner arcs.
    static func roundedMask(cornerRadius radius: CGFloat) -> NSImage {
        let diameter = radius * 2 + 1
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}
