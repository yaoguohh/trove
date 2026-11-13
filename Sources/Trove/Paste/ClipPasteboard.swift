import AppKit

/// Trove's side of the pasteboard: writes a clip back (copy), and pastes it into the app that was
/// frontmost when the panel was summoned. Every write is acknowledged to `ClipboardMonitor`, so the
/// clip Trove just put on the pasteboard is never re-ingested as a new copy.
@MainActor
final class ClipPasteboard {
    private let pasteboard: NSPasteboard
    private let store: ClipStore
    private let monitor: ClipboardMonitor
    /// Keeps the lazy TIFF provider alive while Trove's image owns the pasteboard.
    private var imageOwner: ImagePasteboardOwner?
    private var pasteTarget: PasteTargetSnapshot?

    /// `pasteboard` is injectable so tests can drive a private named pasteboard.
    init(store: ClipStore, monitor: ClipboardMonitor, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.monitor = monitor
        self.pasteboard = pasteboard
    }

    /// Remember the app (and its focused element) that a later `paste` delivers into. Called right
    /// before the panel is summoned, while that app is still frontmost.
    func rememberTarget() {
        pasteTarget = PasteTargetSnapshot.capture(excluding: AppInfo.bundleIdentifier)
    }

    func copy(_ item: Clip) {
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

    /// Copy, then deliver into the remembered target. The single path for every paste from the
    /// panel (Return, click).
    func paste(_ item: Clip) {
        let target = pasteTarget
        pasteTarget = nil
        copy(item)

        let text = item.kind == .image ? nil : store.files.fullText(of: item)
        Task {
            let result = await PasteExecutor.shared.paste(text: text, target: target)
            Log.paste.debug("paste via \(result.strategy.rawValue, privacy: .public) success=\(result.success)")
        }
    }
}

/// Owns the pasteboard after Trove writes an image. The stored PNG bytes go on eagerly (verbatim —
/// what we ingested); the TIFF rendition that a few older consumers insist on is produced only if
/// one actually asks, so a paste never pays for an encode nobody reads.
final class ImagePasteboardOwner: NSObject, NSPasteboardTypeOwner, @unchecked Sendable {
    private let png: Data

    init(png: Data) {
        self.png = png
    }

    func pasteboard(_ sender: NSPasteboard, provideDataForType type: NSPasteboard.PasteboardType) {
        switch type {
        case .png:
            sender.setData(png, forType: .png)
        case .tiff:
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                sender.setData(tiff, forType: .tiff)
            }
        default:
            break
        }
    }
}
