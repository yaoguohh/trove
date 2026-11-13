import AppKit

/// Trove's side of the pasteboard: writes a clip back (copy), and pastes it into the app that was
/// frontmost when the panel was summoned. Every write is acknowledged to `ClipboardMonitor`, so the
/// clip Trove just put on the pasteboard is never re-ingested as a new copy.
@MainActor
final class ClipPasteboard {
    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private let monitor: ClipboardMonitor
    /// Keeps the lazy TIFF provider alive while Trove's image owns the pasteboard.
    private var imageOwner: ImagePasteboardOwner?
    private var pasteTarget: PasteTargetSnapshot?

    /// `pasteboard` is injectable so tests can drive a private named pasteboard.
    init(store: ClipboardStore, monitor: ClipboardMonitor, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.monitor = monitor
        self.pasteboard = pasteboard
    }

    /// Remember the app (and its focused element) that a later `paste` delivers into. Called right
    /// before the panel is summoned, while that app is still frontmost.
    func rememberTarget() {
        pasteTarget = PasteTargetSnapshot.capture(excluding: AppInfo.bundleIdentifier)
    }

    func copy(_ item: ClipboardItem) {
        pasteboard.clearContents()
        if item.kind == .image, let url = store.files.imageURL(for: item), let png = try? Data(contentsOf: url) {
            // The stored PNG bytes go back verbatim: no decode, no TIFF→PNG round trip. The owner
            // supplies a TIFF only if a consumer asks for one.
            let owner = ImagePasteboardOwner(png: png)
            imageOwner = owner
            pasteboard.declareTypes([.png, .tiff], owner: owner)
            pasteboard.setData(png, forType: .png)
        } else {
            // The FULL text (sidecar-backed for big clips), not the inline prefix.
            pasteboard.setString(store.files.fullText(of: item), forType: .string)
        }
        monitor.acknowledgeOwnWrite()
    }

    /// Copy, then deliver into the remembered target. The single hook for every paste from the
    /// panel (Return, click), so it also records the use.
    func paste(_ item: ClipboardItem) {
        let target = pasteTarget
        pasteTarget = nil
        copy(item)
        store.recordUse(item)

        let text = item.kind == .image ? nil : store.files.fullText(of: item)
        Task {
            let result = await PasteExecutor.shared.paste(text: text, target: target)
            Log.paste.debug("paste via \(result.strategy.rawValue, privacy: .public) success=\(result.success)")
        }
    }
}
