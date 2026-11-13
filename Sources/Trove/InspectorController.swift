import AppKit
import SwiftUI

/// Opens a standalone, content-adaptive window that shows a clipboard item at full size — an
/// image scaled to fit, or long text in a scroll view — so the user can inspect and compare
/// contents. It floats above the main panel and several can be open at once for side-by-side
/// comparison. Deliberately a solid, opaque window (not the panel's translucent glass):
/// translucency would bleed the desktop through transparent image regions and tint the
/// content, which defeats faithful inspection.
@MainActor
final class InspectorController: NSObject, NSWindowDelegate {
    /// Open windows are retained here (not via `isReleasedWhenClosed`) so multiple previews can
    /// coexist; each is dropped on `windowWillClose`.
    private var windows: Set<NSWindow> = []
    private let files: ClipFiles

    init(files: ClipFiles) {
        self.files = files
    }

    /// UTF-8 byte budget for anything the inspector lays out in full — the plain-text
    /// `ScrollView` (SwiftUI `Text` has no viewport virtualization) and JSON pretty-printing. The
    /// window shows the clip up to this guard and a notice beyond it; copy/paste still deliver the
    /// complete content.
    nonisolated static let textBudget = 256 * 1024

    /// Bound the inspect-window text to `textBudget` UTF-8 bytes, returning whether it was
    /// clipped (so the view can show a notice). Truly O(cap): for a spilled clip it reads at most
    /// `textBudget + 1` bytes from the sidecar via `FileHandle` — it never materializes the whole
    /// (up-to-ceiling) clip just to show the first 256KB. Resolve this ONCE on the explicit open action
    /// (`show`), never inside a SwiftUI body. A spilled clip whose sidecar is missing degrades to its
    /// inline prefix.
    static func boundedBody(for item: Clip, in files: ClipFiles) -> (text: String, isClipped: Bool) {
        let budget = textBudget
        let head: Data
        let hasMore: Bool
        if let url = files.textURL(for: item), let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: budget + 1)) ?? Data()
            hasMore = data.count > budget
            head = hasMore ? data.prefix(budget) : data
        } else {
            // Inline text (no sidecar) is already ≤ inlineTextCap < budget, so it is never clipped.
            let bytes = Data(item.text.utf8)
            hasMore = bytes.count > budget
            head = hasMore ? bytes.prefix(budget) : bytes
        }
        var text = String(decoding: head, as: UTF8.self)
        // A hard byte cut can split a multi-byte scalar, which decodes to a trailing U+FFFD; drop it
        // (cosmetic) only when we actually clipped.
        if hasMore { while text.last == "\u{FFFD}" { text.removeLast() } }
        return (text, hasMore)
    }

    func show(_ item: Clip, near screen: NSScreen?) {
        let image: NSImage? = item.kind == .image ? ImageCache.image(for: item, in: files) : nil
        let visible = NSScreen.preferring(screen)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.contentSize(for: item, image: image, in: visible)

        let window = InspectorWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.title(for: item)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Default: a normal-level, MANAGED window so it shows in Mission Control and the window
        // cycle like any app window. (Without an explicit Exposé-axis value AppKit treats a .floating
        // window as .transient — hidden from Mission Control.) The pin button in the titlebar (a
        // trailing accessory) flips it to .floating + .fullScreenAuxiliary.
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.minSize = NSSize(width: 320, height: 240)
        window.isMovableByWindowBackground = true
        window.delegate = self

        // Resolve the bounded plain-text body HERE — on the explicit open action — so the bounded
        // sidecar read happens once off the SwiftUI body (which can re-evaluate many times). Only the
        // plain-text branch needs it; image/link/json branches ignore it.
        let plainBody = item.kind == .image ? nil : Self.boundedBody(for: item, in: files)
        let hosting = NSHostingController(rootView: InspectorView(item: item, image: image, plainBody: plainBody))
        // Drop `.intrinsicContentSize` so a `maxWidth/Height: .infinity` root fills the window
        // instead of collapsing to its intrinsic size (the frame-less-Form blank-window pitfall).
        hosting.sizingOptions = [.minSize]
        window.contentViewController = hosting
        window.setContentSize(size)

        // Keep-on-Top control as a trailing TITLEBAR accessory, so it sits in the top-right corner
        // of the titlebar instead of floating over the content. Each window owns its own pin state.
        let pinAccessory = NSTitlebarAccessoryViewController()
        pinAccessory.layoutAttribute = .trailing
        let pinHost = NSHostingView(rootView: PinTitlebarButton(apply: { [weak window] pinned in
            guard let window else { return }
            Self.applyPin(pinned, to: window)
        }))
        pinHost.frame = NSRect(x: 0, y: 0, width: 42, height: 28)
        pinAccessory.view = pinHost
        window.addTitlebarAccessoryViewController(pinAccessory)

        let frame = window.frame
        window.setFrameOrigin(NSPoint(
            x: (visible.midX - frame.width / 2).rounded(),
            y: (visible.midY - frame.height / 2).rounded()
        ))

        windows.insert(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
    }

    /// Image: aspect-preserving fit to a fraction of the screen, never upscaled past 1:1 (a tiny
    /// favicon shouldn't blow up to fullscreen), with a small floor so it's never a sliver.
    /// Text: a comfortable reading column with a sensible default height; content scrolls.
    private static func contentSize(for item: Clip, image: NSImage?, in visible: NSRect) -> NSSize {
        if let image, image.size.width > 0, image.size.height > 0 {
            let fitted = ImageFit.size(
                of: image.size,
                within: CGSize(width: visible.width * 0.80, height: visible.height * 0.85),
                atLeast: CGSize(width: 240, height: 180)
            )
            return NSSize(width: fitted.width.rounded(), height: fitted.height.rounded())
        }
        let width = min(max(560, visible.width * 0.42), 760)
        let height = min(max(360, visible.height * 0.55), visible.height * 0.85)
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private static func title(for item: Clip) -> String {
        String(item.displayTitle.prefix(60))
    }

    /// Flip an inspector window between a normal, Mission-Control-visible window and a floating,
    /// always-on-top one. Set BOTH level and collectionBehavior every time — AppKit derives a
    /// default behavior from the level, so flipping only the level would silently revert
    /// Mission-Control visibility.
    private static func applyPin(_ pinned: Bool, to window: NSWindow) {
        window.level = pinned ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.managed, .participatesInCycle]
        if pinned { behavior.insert(.fullScreenAuxiliary) }
        window.collectionBehavior = behavior
    }
}

/// The inspector. Trove has no main menu, so nothing supplies the usual File/Edit key
/// equivalents: Esc and ⌘W close it here, and ⌘C/⌘A route into the selectable text via
/// `EditingShortcuts`. The panel's key monitor bails when the panel isn't key, so Esc reaches this
/// window instead of dismissing the panel.
private final class InspectorWindow: NSWindow {
    /// Esc → close (the standard cancel action), unless a subview claimed the key first.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if EditingShortcuts.route(event) { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct InspectorView: View {
    let item: Clip
    let image: NSImage?
    /// Bounded plain-text body, resolved once in `show()` (off the body). Nil for image items.
    let plainBody: (text: String, isClipped: Bool)?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.coal)
        } else if item.kind == .image {
            // An image item whose file went missing — show a clear placeholder, not blank.
            ImageUnavailableView(symbolSize: 40, textSize: 14)
                .background(Theme.Surface.coal)
        } else {
            // Detection runs on the bounded inline `text` (cheap); each branch is a pure display
            // layer. Rich previews live ONLY here, never per-card.
            switch InspectorRenderer.detect(item.text, kind: item.kind) {
            case .json(let pretty):
                JSONInspectorView(formatted: pretty, raw: item.text)
            case .url, .plain:
                // A single URL opens in the default browser before this window is ever shown (see
                // PanelController.showInspector); the `.url` case here is a defensive fallback
                // that renders the raw URL as plain text rather than a native web card.
                BoundedPlainText(bounded: plainBody ?? (item.text, false), isTruncated: item.isTruncated)
            }
        }
    }

}

/// The Keep-on-Top toggle hosted in the inspector's titlebar (trailing accessory). Owns its
/// pinned state and calls back to flip the window's level/collectionBehavior.
private struct PinTitlebarButton: View {
    let apply: (Bool) -> Void
    @State private var isPinned = false

    var body: some View {
        Button {
            isPinned.toggle()
            apply(isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPinned ? Theme.accent : Theme.Text.t3)
                .frame(width: 32, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(isPinned ? String(localized: "Unpin") : String(localized: "Keep on Top"))
    }
}
