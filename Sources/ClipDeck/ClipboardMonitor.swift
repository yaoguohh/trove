import AppKit

@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private let store: ClipboardStore
    private var lastChangeCount: Int
    private var timer: Timer?
    private var lastTextWrittenByApp: String?
    private var lastImageDataWrittenByApp: Data?
    private var pasteTargetSnapshot: PasteTargetSnapshot?

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    func copy(_ item: ClipboardItem, asPlainText: Bool = false) {
        pasteboard.clearContents()
        if !asPlainText, item.kind == .image, let image = Self.image(for: item), let data = Self.pngData(for: image) {
            lastImageDataWrittenByApp = data
            pasteboard.writeObjects([image])
        } else {
            lastTextWrittenByApp = item.text
            pasteboard.setString(item.text, forType: .string)
        }
    }

    func copyAndPaste(_ item: ClipboardItem, asPlainText: Bool = false) {
        let targetSnapshot = pasteTargetSnapshot
        copy(item, asPlainText: asPlainText)

        Task { @MainActor in
            let result = await PasteExecutor.shared.paste(item: item, target: targetSnapshot)
            #if DEBUG
            NSLog("ClipDeck paste result: %@, success=%d", result.strategy.rawValue, result.success ? 1 : 0)
            #endif
            clearPasteTarget()
        }
    }

    func rememberPasteTarget() {
        pasteTargetSnapshot = PasteTargetSnapshot.capture(excluding: Bundle.main.bundleIdentifier)
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let appName = sourceApplication?.localizedName ?? "Unknown"

        if let image = NSImage(pasteboard: pasteboard), let data = Self.pngData(for: image) {
            if data == lastImageDataWrittenByApp {
                lastImageDataWrittenByApp = nil
                return
            }
            store.addImage(
                data: data,
                sourceApp: appName,
                sourceBundleIdentifier: sourceApplication?.bundleIdentifier,
                sourceAppPath: sourceApplication?.bundleURL?.path
            )
            return
        }

        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        if text == lastTextWrittenByApp {
            lastTextWrittenByApp = nil
            return
        }

        store.add(
            text: text,
            sourceApp: appName,
            sourceBundleIdentifier: sourceApplication?.bundleIdentifier,
            sourceAppPath: sourceApplication?.bundleURL?.path
        )
    }

    private static func image(for item: ClipboardItem) -> NSImage? {
        guard let url = item.imageFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func clearPasteTarget() {
        pasteTargetSnapshot = nil
    }
}
