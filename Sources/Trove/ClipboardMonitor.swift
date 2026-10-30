import AppKit

@MainActor
final class ClipboardMonitor {
    /// `changeCount` is the only change signal NSPasteboard offers (no notification API), so every
    /// clipboard manager polls it. 0.5s matches Maccy / Clipy / CopyQ.
    static let pollInterval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private var lastChangeCount: Int
    private var timer: Timer?
    private var lastTextWrittenByApp: String?
    private var lastImageDataWrittenByApp: Data?
    /// Keeps the lazy TIFF provider alive while Trove's image owns the pasteboard.
    private var imagePasteboardOwner: ImagePasteboardOwner?
    private var pasteTargetSnapshot: PasteTargetSnapshot?

    /// `pasteboard` is injectable so tests can drive a private named pasteboard.
    init(store: ClipboardStore, pasteboard: NSPasteboard = .general) {
        self.store = store
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so this already runs on the main actor.
            MainActor.assumeIsolated { self?.poll() }
        }
        // Generous tolerance lets the kernel coalesce this wakeup with others (CopyQ does the same);
        // a copy showing up ≤150ms later is imperceptible, the saved wakeups are not.
        timer.tolerance = Self.pollInterval * 0.3
        // `.common` so polling continues while a menu or drag is tracking (default-mode timers pause).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func copy(_ item: ClipboardItem, asPlainText: Bool = false) {
        pasteboard.clearContents()
        if !asPlainText, item.kind == .image, let url = item.imageFileURL, let png = try? Data(contentsOf: url) {
            // The stored PNG bytes go back verbatim: no decode, no TIFF→PNG round trip. The owner
            // supplies a TIFF only if a consumer asks for one. poll() recognises the echo by comparing
            // these exact bytes.
            lastImageDataWrittenByApp = png
            let owner = ImagePasteboardOwner(png: png)
            imagePasteboardOwner = owner
            pasteboard.declareTypes([.png, .tiff], owner: owner)
            pasteboard.setData(png, forType: .png)
        } else {
            // The FULL text (sidecar-backed for big clips). Both the pasteboard write AND the
            // echo-suppression record must use the same full string, or poll() would see the written
            // content as "new" (the inline prefix != full) and re-ingest the clip on every select.
            let full = item.fullText
            lastTextWrittenByApp = full
            pasteboard.setString(full, forType: .string)
        }
    }

    func copyAndPaste(_ item: ClipboardItem, asPlainText: Bool = false) {
        let targetSnapshot = pasteTargetSnapshot
        copy(item, asPlainText: asPlainText)
        // Record the paste as a "use" (the single hook for every paste-from-panel action — keyboard
        // Return/⌥Return and the view's click/menu paste both land here). poll() echo-suppresses this
        // write, so a use never re-enters add(); recordUse only stamps lastUsedAt for the summon bias.
        store.recordUse(item)

        Task { @MainActor in
            let result = await PasteExecutor.shared.paste(item: item, target: targetSnapshot)
            Log.paste.debug("paste via \(result.strategy.rawValue, privacy: .public) success=\(result.success)")
            clearPasteTarget()
        }
    }

    func rememberPasteTarget() {
        pasteTargetSnapshot = PasteTargetSnapshot.capture(excluding: Bundle.main.bundleIdentifier)
    }

    /// One tick: compare `changeCount` (one IPC), and only when it moved read the types + string and
    /// decide. Text is read before any bitmap; bitmaps are read only when the decision says so, so a
    /// rich-text copy never pulls a multi-MB TIFF across the pasteboard server.
    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount

        let types = (pasteboard.types ?? []).map(\.rawValue)
        let string = pasteboard.string(forType: .string)

        switch PasteboardIngest.decide(types: types, string: string) {
        case .ignore(let reason):
            Log.clipboard.debug("skipped pasteboard change: \(String(describing: reason), privacy: .public)")
        case .nothing:
            break
        case .text(let text):
            if text == lastTextWrittenByApp {
                lastTextWrittenByApp = nil
                return
            }
            let source = Self.sourceApplication()
            store.add(
                text: text,
                sourceApp: source.name,
                sourceBundleIdentifier: source.bundleIdentifier,
                sourceAppPath: source.path
            )
        case .image(let type):
            guard let data = pasteboard.data(forType: type.pasteboardType) else { return }
            if data == lastImageDataWrittenByApp {
                lastImageDataWrittenByApp = nil
                return
            }
            // Any other image supersedes the echo record — never pin a stale PNG in memory.
            lastImageDataWrittenByApp = nil
            ingest(PasteboardImagePayload(data: data, type: type), source: Self.sourceApplication())
        }
    }

    private struct SourceApplication {
        let name: String
        let bundleIdentifier: String?
        let path: String?
    }

    private static func sourceApplication() -> SourceApplication {
        let application = NSWorkspace.shared.frontmostApplication
        return SourceApplication(
            name: application?.localizedName ?? "Unknown",
            bundleIdentifier: application?.bundleIdentifier,
            path: application?.bundleURL?.path
        )
    }

    /// Normalise, thumbnail and write the bitmap OFF the main thread, then hand the finished files to
    /// the store. A 4K screenshot used to cost ~0.9s of main-thread TIFF→PNG encoding per copy; PNG
    /// now passes through untouched and the only work is the ≤640px thumbnail, on a background task.
    private func ingest(_ payload: PasteboardImagePayload, source: SourceApplication) {
        guard payload.data.count <= ImageIngest.maxImageBytes else {
            Log.images.notice("skipped a \(payload.data.count) byte pasteboard image (over the \(ImageIngest.maxImageBytes) byte cap)")
            return
        }
        let id = UUID()
        let capturedAt = Date()
        let directory = ClipboardItem.imageDirectoryURL
        let store = self.store
        Task.detached(priority: .userInitiated) {
            guard let png = ImageIngest.pngData(from: payload) else {
                Log.images.error("pasteboard image could not be decoded; dropped")
                return
            }
            let files: ImageIngest.StoredFiles
            do {
                files = try ImageIngest.writeFiles(id: id, png: png, directory: directory)
            } catch {
                Log.images.error("image save failed: \(error.localizedDescription, privacy: .public)")
                return
            }
            await MainActor.run {
                store.addPreparedImage(
                    id: id,
                    files: files,
                    sourceApp: source.name,
                    sourceBundleIdentifier: source.bundleIdentifier,
                    sourceAppPath: source.path,
                    createdAt: capturedAt
                )
            }
        }
    }

    private func clearPasteTarget() {
        pasteTargetSnapshot = nil
    }
}
