import Foundation

/// The on-disk shape of `history.json`.
///
/// `version` records the item format the document was written with. Older documents are migrated
/// while decoding (see `ClipboardItem.init(from:)`) and rewritten by the store on launch.
/// - 1: no `version` key; image clips stored "Image" as text and title; only sidecar-spilled text
///   clips had an identity (`fullTextHash`).
/// - 2: every clip carries `contentHash`; image clips have empty text and no placeholder title.
/// - 3: `link` means a single bare URL (version 2 also marked paragraphs that start with one).
struct StoreDocument: Codable, Sendable {
    static let currentVersion = 3

    var version: Int
    var items: [ClipboardItem]
    var pinboards: [Pinboard]

    init(items: [ClipboardItem], pinboards: [Pinboard]) {
        version = Self.currentVersion
        self.items = items
        self.pinboards = pinboards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try container.decode([ClipboardItem].self, forKey: .items)
        pinboards = try container.decode([Pinboard].self, forKey: .pinboards)
    }
}

/// Reading and writing `history.json`, and sweeping the sidecar directories. Pure file I/O with no
/// knowledge of dedup, undo or pinboards, so `ClipboardStore` stays about the history's rules and a
/// future format change (compact JSON, SQLite) is confined to this file.
struct HistoryPersistence: Sendable {
    enum LoadResult {
        /// No file yet (first launch).
        case missing
        case document(StoreDocument)
        /// Undecodable bytes; a backup copy was written beside the file so nothing is silently lost.
        case corrupt
        /// The file exists but could not be read (permissions, I/O). The caller must not overwrite it.
        case unreadable
    }

    let fileURL: URL

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .missing }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            Log.store.error("history exists but could not be read; not saving this session: \(error.localizedDescription, privacy: .public)")
            return .unreadable
        }
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(StoreDocument.self, from: data) {
            return .document(document)
        }
        backupCorruptFile(data: data)
        return .corrupt
    }

    /// Atomic, pretty-printed write (the file is meant to stay human-readable). Safe to call from any
    /// thread; `HistoryWriter` runs it on its serial queue.
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

/// Serializes history writes. Debounced saves and the quit-time flush go through one serial queue,
/// and a debounced write only lands if no newer save was requested after it was scheduled — so a
/// stale document can never be written after a newer one (in particular, after `flush`).
final class HistoryWriter: @unchecked Sendable {
    /// How long rapid changes coalesce before one write.
    static let debounce: TimeInterval = 0.3

    private let fileURL: URL
    private let queue = DispatchQueue(label: "io.github.yaoguohh.trove.history-writer", qos: .utility)
    // Guarded by `lock`: bumped on the main actor, read on `queue`.
    private let lock = NSLock()
    private var generation = 0

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func schedule(_ document: StoreDocument) {
        let scheduled = bumpGeneration()
        queue.asyncAfter(deadline: .now() + Self.debounce) { [self] in
            guard currentGeneration() == scheduled else { return }
            HistoryPersistence.write(document, to: fileURL)
        }
    }

    /// Writes now and waits; any write still pending is superseded.
    func flush(_ document: StoreDocument) {
        _ = bumpGeneration()
        queue.sync {
            HistoryPersistence.write(document, to: fileURL)
        }
    }

    private func bumpGeneration() -> Int {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    private func currentGeneration() -> Int {
        lock.withLock { generation }
    }
}
