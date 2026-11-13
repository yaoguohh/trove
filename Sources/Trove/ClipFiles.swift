import SwiftUI

/// Where one history keeps its files — `history.json` plus the `images/` and `texts/` sidecar
/// directories under `root` — and the only code that turns a clip's file names into paths or reads
/// its sidecar text. The app uses `.live`; tests inject a temporary root, so every file path
/// (sidecar spill, launch sweep, thumbnail backfill, eviction) runs for real without touching the
/// user's data.
struct ClipFiles: Sendable, Equatable {
    let root: URL

    static var live: ClipFiles { ClipFiles(root: AppPaths.applicationSupport) }

    var historyFile: URL { root.appendingPathComponent("history.json") }
    var imageDirectory: URL { root.appendingPathComponent("images", isDirectory: true) }
    /// Full text of clips too large to keep inline in `history.json` (see `Clip.sidecarThreshold`).
    var textDirectory: URL { root.appendingPathComponent("texts", isDirectory: true) }

    func imageURL(for item: Clip) -> URL? {
        item.imageFileName.map { imageDirectory.appendingPathComponent($0) }
    }

    func thumbnailURL(for item: Clip) -> URL? {
        item.thumbnailFileName.map { imageDirectory.appendingPathComponent($0) }
    }

    func textURL(for item: Clip) -> URL? {
        item.textFileName.map { textDirectory.appendingPathComponent($0) }
    }

    /// The FULL verbatim text, for the consumers that must deliver complete content: copy, paste and
    /// drag-out. For an inline clip this is just `text` (no IO). For a spilled clip it does cached disk
    /// IO and degrades to the inline prefix if the sidecar is missing. MUST NOT be called from a
    /// SwiftUI body or per-keystroke search — those use `text` / `excerpt` (the bounded inline prefix).
    @MainActor
    func fullText(of item: Clip) -> String {
        guard let url = textURL(for: item) else { return item.text }
        let key = url.path as NSString
        if let cached = Self.fullTextCache.object(forKey: key) { return cached as String }
        guard let loaded = try? String(contentsOf: url, encoding: .utf8) else {
            Log.store.error("full-text sidecar unreadable (\(url.lastPathComponent, privacy: .public)); using the inline prefix only")
            // Memoize the fallback so a degraded clip doesn't re-stat + re-log on every paste/drag.
            Self.fullTextCache.setObject(item.text as NSString, forKey: key, cost: item.text.utf8.count)
            return item.text
        }
        Self.fullTextCache.setObject(loaded as NSString, forKey: key, cost: loaded.utf8.count)
        return loaded
    }

    /// Writes a spilled clip's full text atomically and returns its file name.
    func writeText(_ text: String, for id: UUID) throws -> String {
        try FileManager.default.createDirectory(at: textDirectory, withIntermediateDirectories: true)
        let fileName = "\(id.uuidString).txt"
        try Data(text.utf8).write(to: textDirectory.appendingPathComponent(fileName), options: .atomic)
        return fileName
    }

    /// Deletes every file a clip owns (image, thumbnail, text sidecar). A small image's thumbnail IS
    /// the image, so the second remove is then a harmless no-op.
    func removeFiles(of item: Clip) {
        for url in [imageURL(for: item), thumbnailURL(for: item), textURL(for: item)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Resident decoded full-text bound (mirrors `ImageCache`). Path-keyed; each entry is charged its
    /// UTF-8 byte size, so a single oversized read can't pin more than the ceiling.
    @MainActor private static let fullTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()
}

extension EnvironmentValues {
    /// The history's files, set at the root of every view tree that shows clips.
    @Entry var clipFiles: ClipFiles = .live
}
