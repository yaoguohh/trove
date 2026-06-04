import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class ClipboardPanelController {
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    private let onOpenSettings: () -> Void
    private var panel: NSPanel?
    private var hostingController: NSHostingController<ClipboardPanelView>?
    // App-lifetime observer (the controller is held by AppDelegate for the whole run), so it never
    // needs explicit removal; the [weak self] closure keeps it from retaining the controller.
    private var resignActiveObserver: NSObjectProtocol?
    private let model: PanelViewModel
    private lazy var previewController = PreviewWindowController()
    private lazy var quickLook = QuickLookBubbleController()

    /// Panel corner radius. The glass mask (AppKit) and the content clip (SwiftUI) must use
    /// the same value — keep `ClipboardPanelView`'s 16pt corners in sync with this.
    static let cornerRadius: CGFloat = 16

    /// Panel non-card width (toolbar + side insets around the card strip). Single source of truth for
    /// both panel sizing (`position()`) and the ⌘←/⌘→ page size (`visibleCardCount()`).
    private static let chromeWidth: CGFloat = 96

    var isVisible: Bool {
        panel?.isVisible == true
    }

    init(store: ClipboardStore, monitor: ClipboardMonitor, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        self.model = PanelViewModel(store: store)
        // The Space peek is one-shot: it shows the card selected at the moment Space was pressed.
        // ANY later selection change (←/→ navigation or hover) dismisses it instead of letting the
        // bubble follow — a bubble that tracks fast navigation is disorienting.
        self.model.onSelectionChange = { [weak self] in self?.quickLook.hide() }
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }
        // Activate ClipDeck so the panel is a fully-interactive key window of the active
        // app. A non-activating panel of a background app intermittently swallows the
        // first click/drag/key on its content; the paste target was already snapshotted
        // before showing and is re-activated on paste, so this doesn't affect pasting.
        NSApp.activate()
        panel.alphaValue = 1
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        // Fresh state on every (re)show. The SwiftUI view focuses the search field (on showToken),
        // so typing filters immediately with no lost first character, and ←/→ navigate the cards via
        // the field's onKeyPress interception.
        model.prepareForShow()
    }

    /// `animated: false` (default) hides instantly — required during a drag (the
    /// event-tracking run loop defers display updates) and for paste (must be snappy).
    /// `animated: true` plays a drawer-style collapse for plain dismissals (Esc / hotkey).
    func hide(animated: Bool = false) {
        // Any panel dismissal (paste, Esc, hotkey, focus loss, drag) also dismisses the peek bubble
        // — a single chokepoint so the bubble can never outlive the panel.
        quickLook.hide()
        guard let panel, panel.isVisible, animated else {
            panel?.alphaValue = 0
            panel?.orderOut(nil)
            // Force the visibility change to the window server this frame.
            panel?.displayIfNeeded()
            CATransaction.flush()
            return
        }

        // Drawer collapse: slide down + fade out, then order out.
        let startFrame = panel.frame
        var endFrame = startFrame
        endFrame.origin.y -= startFrame.height
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(endFrame, display: true)
        }, completionHandler: { [weak self] in
            // NSAnimationContext completion runs on the main thread.
            MainActor.assumeIsolated {
                guard let panel = self?.panel, panel.alphaValue < 0.5 else { return } // re-shown mid-animation
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrame(startFrame, display: false)
            }
        })
    }

    private func createPanel() {
        let root = ClipboardPanelView(
            store: store,
            monitor: monitor,
            model: model,
            close: { [weak self] in self?.hide() },
            reopen: { [weak self] in self?.show() },
            openSettings: { [weak self] in self?.onOpenSettings() },
            preview: { [weak self] item in self?.showPreview(item) },
            handleKey: { [weak self] key, modifiers in self?.handleKey(key, modifiers) ?? false }
        )
        let hosting = ClickThroughHostingController(rootView: root)
        hostingController = hosting
        let panel = ClipDeckPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 450),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let containerView = NSView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor

        // Adaptive glass that follows the app Appearance and HIDES background text the way the Dock
        // does. The blur radius is ~constant across materials; what smears text into an unreadable
        // wash is the material's baked-in fill density — so use the DENSEST materials, not the
        // thinnest: .hudWindow (dark) / .menu (light). .underWindowBackground (used before) is the
        // *thinnest*, which let background text read through. The material is chosen per effective
        // appearance inside AdaptiveGlassView so it updates live when the user switches Light/Dark.
        let glassView = AdaptiveGlassView(frame: .zero)
        glassView.blendingMode = .behindWindow
        glassView.state = .active
        // Denser, more saturated variant — extra text suppression at no transparency cost.
        glassView.isEmphasized = true
        // Full opacity is intentional: translucency must come from the material's heavy BLUR, not
        // from alpha. Lowering alpha lets the raw, un-blurred desktop bleed through — so background
        // window TEXT shows through legibly (what you saw). At alpha 1.0 the blur smears that text
        // into an unreadable wash (the Dock's trick) while a plain desktop still shows through.
        glassView.alphaValue = 1.0
        glassView.wantsLayer = true
        // maskImage clips the live blur to the rounded rect cleanly; cornerRadius + masksToBounds
        // leaves faint blur fringing at the corners. capInsets stretch the mask to any size.
        glassView.maskImage = .roundedMask(cornerRadius: Self.cornerRadius)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(glassView)
        containerView.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: containerView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hosting.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        // Suppress any implicit order-in/out animation so hide() applies synchronously
        // even inside the drag's event-tracking run loop.
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        // Window state restoration (default on) can silently override makeFirstResponder and
        // leave focus unstable across show/hide; this panel is transient, so opt out.
        panel.isRestorable = false
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 720, height: 240)
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = containerView
        self.panel = panel

        // Spotlight-style auto-dismiss: collapse the panel the moment ClipDeck stops being the
        // active app (the user clicked another app or the desktop). didResignActive fires ONLY on
        // a true app deactivation — moving focus to our OWN preview/settings window keeps ClipDeck
        // active, so the panel correctly stays open beneath them for side-by-side comparison.
        // Because the panel can no longer linger while another app is focused, the old *global* Esc
        // monitor became unreachable and was removed; the local key monitor's Esc (fires only while
        // the panel is key) is now the single Esc path. `hidesOnDeactivate` is left false on purpose
        // so this animated, monitor-cleaning hide() runs instead of AppKit's abrupt orderOut.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so this runs on the main actor.
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                self.hide(animated: true)
            }
        }
    }

    /// The display under the mouse, recomputed each show (the global hotkey can summon the
    /// panel onto whichever screen the user is looking at). `NSScreen.main` follows the key
    /// window, which on a background-app hotkey summon is the wrong monitor (or nil).
    private func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func position(_ panel: NSPanel) {
        // No display (headless / all displays asleep / screen-sharing teardown) → leave the panel
        // as is rather than crash; it isn't visible in that state anyway. (NSScreen.screens can be
        // empty, so don't force-index it.)
        guard let vis = targetScreen()?.visibleFrame else { return }
        let bottomMargin = max(12, min(28, vis.height * 0.020))

        // Reference card footprint (kept in CardMetrics so panel sizing can't drift from the card's
        // real geometry); scale the visible card *count* with the display, not the card.
        let cardW = CardMetrics.referenceCardWidth
        let gap = CardMetrics.referenceCardSpacing
        let chrome = Self.chromeWidth       // toolbar + side insets around the card strip

        // Large displays fill the width edge-to-edge (full-width look on request); a hair of side
        // margin keeps the rounded corners + shadow readable. Smaller displays keep the
        // content-driven width with generous margins so it doesn't sprawl.
        let isLargeDisplay = vis.width >= 1680
        let width: CGFloat
        if isLargeDisplay {
            width = vis.width - 16
        } else {
            let sideMargin = max(24, min(80, vis.width * 0.03))
            let contentMax = vis.width - sideMargin * 2
            let capWidth = min(vis.width * 0.90, 2480, contentMax)
            let screenCapacity = max(3, min(8, Int((capWidth - chrome + gap) / (cardW + gap))))
            let itemCount = max(1, min(screenCapacity, store.matches(query: "").count))
            let desiredWidth = CGFloat(itemCount) * cardW + CGFloat(max(0, itemCount - 1)) * gap + chrome
            width = min(contentMax, max(720, desiredWidth))
        }
        // Taller panel so the enlarged cards can reach their height cap on a big display.
        let height = min(376, max(256, vis.height * 0.26))

        let origin = NSPoint(
            x: (vis.midX - width / 2).rounded(),
            y: (vis.minY + bottomMargin).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    /// Keyboard routing. Called from the search field's `onKeyPress` (the field is always the
    /// focused field, so this only runs while the panel — not a preview or a rename editor — owns
    /// the keyboard). Returns true to intercept the key (SwiftUI treats it as `.handled`), false to
    /// let it fall through and edit the search text. The decision is the pure, unit-tested
    /// `PanelKeyboard.intent`; this only applies the side effects.
    func handleKey(_ key: KeyEquivalent, _ modifiers: EventModifiers) -> Bool {
        guard let panel, panel.isVisible else { return false }
        // While an input method is composing (Chinese/Japanese/…), Space/Return/arrows/Esc belong to
        // the candidate window — never intercept them, or e.g. Space (commit candidate) would toggle
        // the peek. Returning false lets the key fall through to the IME.
        if isComposingText() { return false }
        switch PanelKeyboard.intent(
            key: key,
            modifiers: modifiers,
            state: PanelInputState(
                queryIsEmpty: model.query.isEmpty,
                hasSelection: model.selectedItem != nil,
                quickLookVisible: quickLook.isVisible
            )
        ) {
        case .passThrough:
            return false
        case .dismissQuickLook:
            quickLook.hide()
        case .closePanel:
            hide(animated: true)
        case .clearQuery:
            model.query = ""
            model.selectFirst()
        case .paste(let plainText):
            performPaste(asPlainText: plainText)
        case .moveSelection(let delta):
            model.moveSelection(by: delta)
        case .pageSelection(let direction):
            model.moveSelection(by: direction * visibleCardCount())
        case .deleteSelectedCard:
            deleteSelectedCard()
        case .toggleQuickLook:
            // The bubble's expand button hands off to the full standalone preview window.
            quickLook.onExpand = { [weak self] item in self?.showPreview(item) }
            quickLook.toggle(model: model, over: panel)
        }
        return true
    }

    /// True while an input method has uncommitted (marked) text in the search field, so the
    /// candidate window — not our shortcuts — owns Space/Return/arrows. Checks both the panel's first
    /// responder and its shared field editor, since SwiftUI may route input through either.
    private func isComposingText() -> Bool {
        if let textView = panel?.firstResponder as? NSTextView, textView.hasMarkedText() { return true }
        if let editor = panel?.fieldEditor(false, for: nil) as? NSTextView, editor.hasMarkedText() { return true }
        return false
    }

    private func performPaste(asPlainText: Bool) {
        guard let item = model.selectedItem else { return }
        hide()
        monitor.copyAndPaste(item, asPlainText: asPlainText)
    }

    /// Delete the selected card (⌦ or ⌘⌫) and re-select a sensible neighbor at the same position so
    /// the user can keep deleting without losing their place. The panel stays open; an open peek
    /// re-fits (or hides if the list emptied) via the selection-change hook.
    private func deleteSelectedCard() {
        guard let item = model.selectedItem else { return }
        let index = model.filteredItems.firstIndex { $0.id == item.id } ?? 0
        store.delete(item)
        let remaining = model.filteredItems
        model.selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }

    /// Roughly how many cards are visible across the panel — the page size for ⌘←/⌘→. Derived from
    /// the panel width and the card's reference footprint (the count, not the card, scales with the
    /// display, so the reference width tracks the on-screen card).
    private func visibleCardCount() -> Int {
        guard let panel else { return 3 }
        let chrome = Self.chromeWidth
        let unit = CardMetrics.referenceCardWidth + CardMetrics.referenceCardSpacing
        guard unit > 0 else { return 3 }
        return max(1, Int((panel.frame.width - chrome) / unit))
    }

    /// Open a standalone, content-adaptive preview window for the item. The panel stays open
    /// (floating beneath the preview) so the user can keep comparing items.
    private func showPreview(_ item: ClipboardItem) {
        previewController.show(item, near: panel?.screen)
    }
}

/// A borderless panel that can still become key so the hosted SwiftUI search field can focus and
/// receive keyboard input; navigation/action keys are intercepted by the field's `.onKeyPress`.
private final class ClipDeckPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// An NSVisualEffectView that picks the densest text-hiding material for its current appearance
/// (dark → .hudWindow, light → .menu) and re-picks when the appearance changes, so flipping the
/// Appearance preference updates the glass live. The blur is ~constant across materials; the dense
/// fill is what smears background window text into an unreadable wash (the Dock's behavior), which
/// the thin .underWindowBackground could not do.
private final class AdaptiveGlassView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyAdaptiveMaterial()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyAdaptiveMaterial()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAdaptiveMaterial()
    }

    private func applyAdaptiveMaterial() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        material = isDark ? .hudWindow : .menu
    }
}

private extension NSImage {
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

