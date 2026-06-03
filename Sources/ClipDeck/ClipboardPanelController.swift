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
    private var keyMonitor: Any?
    private var globalEscapeMonitor: Any?
    private let model: PanelViewModel
    private lazy var previewController = PreviewWindowController()

    /// Panel corner radius. The glass mask (AppKit) and the content clip (SwiftUI) must use
    /// the same value — keep `ClipboardPanelView`'s 16pt corners in sync with this.
    static let cornerRadius: CGFloat = 16

    var isVisible: Bool {
        panel?.isVisible == true
    }

    init(store: ClipboardStore, monitor: ClipboardMonitor, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.monitor = monitor
        self.onOpenSettings = onOpenSettings
        self.model = PanelViewModel(store: store)
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
        // Fresh state + refocus the always-on search field on every (re)show. The search
        // field stays first responder, so typing never loses its first character; the key
        // monitor below redirects navigation/confirm keys to the highlighted card.
        model.prepareForShow()
        installKeyMonitor()
    }

    /// `animated: false` (default) hides instantly — required during a drag (the
    /// event-tracking run loop defers display updates) and for paste (must be snappy).
    /// `animated: true` plays a drawer-style collapse for plain dismissals (Esc / hotkey).
    func hide(animated: Bool = false) {
        removeKeyMonitor()
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
            preview: { [weak self] item in self?.showPreview(item) }
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
        let chrome: CGFloat = 96            // toolbar + side insets around the card strip

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

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Local monitor: receives keyDown before it reaches the (always-focused) search
        // field, so navigation/confirm keys get redirected to the selected card while typing
        // and ←/→ text editing still flow through to the field. See handleKeyDown.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event) ?? event
        }
        // Global monitor: the panel floats above other apps (hidesOnDeactivate = false), so
        // Esc must dismiss it even when another app is active — where the local monitor no
        // longer fires. Observe-only; relies on the Accessibility trust ClipDeck already holds.
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == KeyCode.escape else { return }
            self.hide(animated: true)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let globalEscapeMonitor {
            NSEvent.removeMonitor(globalEscapeMonitor)
            self.globalEscapeMonitor = nil
        }
    }

    /// Keyboard model (from the design research): the search field is always first responder;
    /// this monitor redirects navigation/confirm keys to the highlighted card and consumes
    /// them (returns nil) so the text cursor doesn't move, while typing and ←/→ in the search
    /// region pass straight through. IME composition (marked text) is never intercepted.
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let panel, panel.isVisible else { return event }
        // A preview window (or any other ClipDeck window) is key — let it own its keys (so Esc
        // closes the preview, not the panel). The local monitor is app-wide, so without this
        // the panel would swallow the preview's Esc.
        guard panel.isKeyWindow else { return event }
        // While an input method is composing (Chinese/Japanese/etc.), the candidate window
        // owns the arrows and Return — never intercept marked (composing) text.
        if isComposingText() { return event }

        // Arrow keys carry .function/.numericPad in their flags inherently, so gate the
        // shortcuts on the *real* modifiers (⌘⌃⌥⇧) only — otherwise ←/→/↑/↓ never match.
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.keyCode

        // Esc: clear a non-empty search first, otherwise close.
        if key == KeyCode.escape, mods.isEmpty {
            if model.query.isEmpty {
                hide(animated: true)
            } else {
                model.query = ""
                model.selectFirst()
            }
            return nil
        }

        // Return: editing → leave editing for the card row (a lone result is already the
        // default selection); card row → paste the selection. ⌥Return always pastes as plain.
        if key == KeyCode.returnKey || key == KeyCode.keypadEnter {
            if mods == [.option] { performPaste(asPlainText: true); return nil }
            guard mods.isEmpty else { return event }
            if model.isEditing, model.filteredItems.count != 1 {
                // Editing with multiple results: drop to the card row to pick.
                model.isEditing = false
            } else {
                // Card row, or editing with a single result: paste the selection in one press.
                performPaste(asPlainText: false)
            }
            return nil
        }

        // ⌃N / ⌃P move the card selection (Emacs aliases), leaving the editing field.
        if mods == [.control] {
            switch key {
            case KeyCode.n: model.isEditing = false; model.moveSelection(by: 1); return nil
            case KeyCode.p: model.isEditing = false; model.moveSelection(by: -1); return nil
            default: return event
            }
        }

        guard mods.isEmpty else { return event }

        if model.isEditing {
            // Editing the search field: ↓ drops to the card row, ↑ is a no-op (already top),
            // and ←/→ + typing + backspace flow to the field.
            switch key {
            case KeyCode.downArrow: model.isEditing = false; return nil
            case KeyCode.upArrow: return nil
            default: return event
            }
        }

        // Card row (default): ←/→ move the selection, ↑ goes up to the search field, ↓ is a
        // no-op (already the bottom row). A printable key (or backspace) enters editing,
        // carrying the keystroke so the first character is never lost.
        switch key {
        case KeyCode.leftArrow: model.moveSelection(by: -1); return nil
        case KeyCode.rightArrow: model.moveSelection(by: 1); return nil
        case KeyCode.upArrow: model.isEditing = true; return nil
        case KeyCode.downArrow: return nil
        case KeyCode.delete:
            if !model.query.isEmpty {
                model.query.removeLast()
                model.isEditing = true
            }
            return nil
        default:
            // A printable key enters editing, carrying the keystroke so the first char isn't lost.
            guard let chars = event.characters, let scalar = chars.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value < 0xF700, scalar.value != 0x7F else {
                return event
            }
            model.query.append(chars)
            model.isEditing = true
            return nil
        }
    }

    private func performPaste(asPlainText: Bool) {
        guard let item = model.selectedItem else { return }
        hide()
        monitor.copyAndPaste(item, asPlainText: asPlainText)
    }

    /// Open a standalone, content-adaptive preview window for the item. The panel stays open
    /// (floating beneath the preview) so the user can keep comparing items.
    private func showPreview(_ item: ClipboardItem) {
        previewController.show(item, near: panel?.screen)
    }

    /// True while an input method has uncommitted (marked) text, so the candidate window —
    /// not our shortcuts — owns the arrows/Return. Checks both the panel's first responder
    /// and its field editor, since SwiftUI may route input through either.
    private func isComposingText() -> Bool {
        if let textView = panel?.firstResponder as? NSTextView, textView.hasMarkedText() { return true }
        if let editor = panel?.fieldEditor(false, for: nil) as? NSTextView, editor.hasMarkedText() { return true }
        return false
    }
}

/// A borderless, non-activating panel that can still become key so the hosted
/// SwiftUI view receives keyboard events. Arrow/return selection is handled by the
/// SwiftUI view's `.onKeyPress`; Escape by the controller's local event monitor.
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

