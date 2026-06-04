import AppKit
import SwiftUI

/// Opens a standalone, content-adaptive window that shows a clipboard item at full size — an
/// image scaled to fit, or long text in a scroll view — so the user can inspect and compare
/// contents. It floats above the main panel and several can be open at once for side-by-side
/// comparison. Deliberately a solid, opaque window (not the panel's translucent glass):
/// translucency would bleed the desktop through transparent image regions and tint the
/// content, which defeats faithful inspection.
@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    /// Open windows are retained here (not via `isReleasedWhenClosed`) so multiple previews can
    /// coexist; each is dropped on `windowWillClose`.
    private var windows: Set<NSWindow> = []

    func show(_ item: ClipboardItem, near screen: NSScreen?) {
        let image: NSImage? = item.kind == .image
            ? item.imageFileURL.flatMap { ImageCache.image(at: $0) }
            : nil
        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.contentSize(for: item, image: image, in: visible)

        let window = PreviewWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = Self.title(for: item)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        // Default: a normal-level, MANAGED window so it shows in Mission Control and the window
        // cycle like any app window. (.floating + the previous behavior set had no Exposé-axis
        // value, so AppKit defaulted it to .transient — hidden from Mission Control.) The pin
        // button in the titlebar (a trailing accessory) flips it to .floating + .fullScreenAuxiliary.
        window.level = .normal
        window.collectionBehavior = [.managed, .participatesInCycle]
        window.minSize = NSSize(width: 320, height: 240)
        window.isMovableByWindowBackground = true
        window.delegate = self

        let hosting = NSHostingController(rootView: ClipPreviewView(item: item, image: image))
        // Drop `.intrinsicContentSize` so a `maxWidth/Height: .infinity` root fills the window
        // instead of collapsing to its intrinsic size (the SettingsView blank-window pitfall).
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
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.remove(window)
    }

    /// Image: aspect-preserving fit to a fraction of the screen, never upscaled past 1:1 (a tiny
    /// favicon shouldn't blow up to fullscreen), with a small floor so it's never a sliver.
    /// Text: a comfortable reading column with a sensible default height; content scrolls.
    private static func contentSize(for item: ClipboardItem, image: NSImage?, in visible: NSRect) -> NSSize {
        if let image, image.size.width > 0, image.size.height > 0 {
            let maxW = visible.width * 0.80
            let maxH = visible.height * 0.85
            let fit = min(maxW / image.size.width, maxH / image.size.height)
            let scale = min(fit, 1.0)
            let width = max(image.size.width * scale, 240)
            let height = max(image.size.height * scale, 180)
            return NSSize(width: width.rounded(), height: height.rounded())
        }
        let width = min(max(560, visible.width * 0.42), 760)
        let height = min(max(360, visible.height * 0.55), visible.height * 0.85)
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    private static func title(for item: ClipboardItem) -> String {
        guard item.kind != .image else { return item.kind.title }
        let trimmed = item.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? item.kind.title : String(trimmed.prefix(60))
    }

    /// Flip a preview window between a normal, Mission-Control-visible window and a floating,
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

/// Esc closes the preview (the standard cancel action). The panel's key monitor bails when the
/// panel isn't key, so Esc reaches this window's responder chain instead of dismissing the panel.
private final class PreviewWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private struct ClipPreviewView: View {
    let item: ClipboardItem
    let image: NSImage?

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
                .background(Color(nsColor: .windowBackgroundColor))
        } else if item.kind == .image {
            // An image item whose file went missing — show a clear placeholder, not blank.
            VStack(spacing: 10) {
                Image(systemName: "photo")
                    .font(.system(size: 40, weight: .medium))
                Text("Image unavailable")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ScrollView {
                Text(item.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

}

/// The Keep-on-Top toggle hosted in the preview window's titlebar (trailing accessory). Owns its
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
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isPinned ? String(localized: "Unpin") : String(localized: "Keep on Top"))
    }
}
