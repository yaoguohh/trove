import AppKit

/// Watches the system pasteboard and adds every new copy to the history. Writing clips back (copy,
/// paste) is `ClipPasteboard`'s job; it tells the monitor about its own writes.
@MainActor
final class ClipboardMonitor {
    /// `changeCount` is the only change signal NSPasteboard offers (no notification API), so every
    /// clipboard manager polls it. 0.5s matches Maccy / Clipy / CopyQ.
    static let pollInterval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private let store: ClipboardStore
    private var lastChangeCount: Int
    private var timer: Timer?

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

    /// Treat whatever is on the pasteboard now as already seen. `ClipPasteboard` calls this right
    /// after writing a clip back, so Trove's own write is never ingested as a new copy.
    func acknowledgeOwnWrite() {
        lastChangeCount = pasteboard.changeCount
    }

    /// One tick: compare `changeCount` (one IPC), and only when it moved read the types + string and
    /// decide. Text is read before any bitmap; bitmaps are read only when the decision says so, so a
    /// rich-text copy never pulls a multi-MB TIFF across the pasteboard server.
    func poll() {
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
            let source = Self.sourceApplication()
            store.add(
                text: text,
                sourceApp: source.name,
                sourceBundleIdentifier: source.bundleIdentifier,
                sourceAppPath: source.path
            )
        case .image(let type):
            guard let data = pasteboard.data(forType: type.pasteboardType) else { return }
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
    /// the store. Encoding a 4K TIFF screenshot to PNG takes ~0.9s, so none of it may run on the main
    /// thread; a PNG passes through untouched and only its thumbnail is generated.
    private func ingest(_ payload: PasteboardImagePayload, source: SourceApplication) {
        guard payload.data.count <= ImageIngest.maxImageBytes else {
            Log.images.notice("skipped a \(payload.data.count) byte pasteboard image (over the \(ImageIngest.maxImageBytes) byte cap)")
            return
        }
        let id = UUID()
        let capturedAt = Date()
        let directory = store.files.imageDirectory
        let store = self.store
        Task.detached(priority: .userInitiated) {
            guard let png = ImageIngest.pngData(from: payload) else {
                Log.images.error("pasteboard image could not be decoded; dropped")
                return
            }
            let contentHash = ClipboardItem.hash(png)
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
                    contentHash: contentHash,
                    sourceApp: source.name,
                    sourceBundleIdentifier: source.bundleIdentifier,
                    sourceAppPath: source.path,
                    createdAt: capturedAt
                )
            }
        }
    }
}
