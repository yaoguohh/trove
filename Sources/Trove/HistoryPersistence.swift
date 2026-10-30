import Foundation

/// The on-disk shape of `history.json`.
struct StoreDocument: Codable, Sendable {
    var items: [ClipboardItem]
    var pinboards: [Pinboard]
}

/// Reading and writing `history.json`, and sweeping the sidecar directories. Pure file I/O with no
/// knowledge of dedup, undo or pinboards, so `ClipboardStore` stays about the history's rules and a
/// future format change (compact JSON, SQLite) is confined to this file.
struct HistoryPersistence: Sendable {
    enum LoadResult {
        /// No file yet (first launch).
        case missing
        case document(StoreDocument)
        /// The pre-pinboard format: a bare array of items.
        case legacy([ClipboardItem])
        /// Undecodable bytes; a backup copy was written beside the file so nothing is silently lost.
        case corrupt
    }

    let fileURL: URL

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        guard let data = try? Data(contentsOf: fileURL) else { return .missing }
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(StoreDocument.self, from: data) {
            return .document(document)
        }
        if let legacy = try? decoder.decode([ClipboardItem].self, from: data) {
            return .legacy(legacy)
        }
        backupCorruptFile(data: data)
        return .corrupt
    }

    /// Atomic, pretty-printed write (the file is meant to stay human-readable). Safe to call from any
    /// thread; `ClipboardStore.scheduleSave` runs it on a utility task.
    static func write(_ document: StoreDocument, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(document)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.store.error("history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes files in a sidecar directory that no item references anymore (orphans left behind by
    /// deletes/trims in prior versions or by a crash between a sidecar write and the history persist).
    static func removeUnreferencedFiles(in directory: URL, referenced: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    private func backupCorruptFile(data: Data) {
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("history.corrupt-\(suffix).json")
        do {
            try data.write(to: backupURL, options: .atomic)
            Log.store.error("history could not be decoded; preserved a backup at \(backupURL.lastPathComponent, privacy: .public)")
        } catch {
            Log.store.error("history could not be decoded and backup failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
