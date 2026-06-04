import Foundation

enum ClipboardScope {
    case history
    case pinned
}

struct ClipboardSearchFilter: Equatable {
    var scope: ClipboardScope = .history
    var kind: ClipboardKind?
    var pinboardID: UUID?
}

private struct StoreDocument: Codable, Sendable {
    var items: [ClipboardItem]
    var pinboards: [Pinboard]
}

@MainActor
final class ClipboardStore: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var pinboards: [Pinboard] = []

    private let maxItems = 500
    private let decoder = JSONDecoder()
    private let fileURL: URL
    private let managesImageFiles: Bool
    private var isLoading = false
    private var saveGeneration = 0

    /// `storeURL` is injectable so tests can run against a temp file without
    /// touching the user's real Application Support directory.
    init(storeURL: URL? = nil) {
        managesImageFiles = (storeURL == nil)
        fileURL = storeURL ?? AppPaths.historyFileURL
        load()
        ensureDefaultPinboards()
        if managesImageFiles {
            reconcileImageFiles()
        }
    }

    func add(text: String, sourceApp: String, sourceBundleIdentifier: String? = nil, sourceAppPath: String? = nil) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        if let existing = items.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalized }) {
            var item = items.remove(at: existing)
            item.createdAt = Date()
            item.sourceApp = sourceApp
            item.sourceBundleIdentifier = sourceBundleIdentifier
            item.sourceAppPath = sourceAppPath
            items.insert(item, at: 0)
        } else {
            // Dedup on the normalized form, but store the original text verbatim so
            // copied-then-pasted content stays byte-for-byte identical (preserving
            // any intentional leading/trailing whitespace or newlines).
            let item = ClipboardItem(
                text: text,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceAppPath: sourceAppPath,
                kind: ClipboardItem.detectKind(for: text)
            )
            items.insert(item, at: 0)
        }

        trim()
        scheduleSave()
    }

    func addImage(
        data: Data,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        sourceAppPath: String? = nil
    ) {
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        do {
            try FileManager.default.createDirectory(
                at: ClipboardItem.imageDirectoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: ClipboardItem.imageDirectoryURL.appendingPathComponent(fileName), options: .atomic)
        } catch {
            NSLog("ClipDeck image save failed: \(error.localizedDescription)")
            return
        }

        let item = ClipboardItem(
            id: id,
            text: "Image",
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceAppPath: sourceAppPath,
            imageFileName: fileName,
            kind: .image,
            title: "Image"
        )
        items.insert(item, at: 0)
        trim()
        scheduleSave()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        if !items[index].isPinned {
            items[index].pinboardID = nil
        }
        sortForPins()
        scheduleSave()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        Self.removeImageFile(for: item)
        scheduleSave()
    }

    func move(_ item: ClipboardItem, to pinboard: Pinboard?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].pinboardID = pinboard?.id
        items[index].isPinned = pinboard != nil
        sortForPins()
        scheduleSave()
    }

    /// Set or clear a clip's custom display name (shown in the card header; also searchable). An
    /// empty/nil name reverts the card to its kind label.
    func rename(_ item: ClipboardItem, to title: String?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].title = title
        scheduleSave()
    }

    func createPinboard(named name: String, colorName: String = "blue") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pinboards.append(Pinboard(name: trimmed, colorName: colorName))
        scheduleSave()
    }

    func deletePinboard(_ pinboard: Pinboard) {
        pinboards.removeAll { $0.id == pinboard.id }
        for index in items.indices where items[index].pinboardID == pinboard.id {
            items[index].pinboardID = nil
            items[index].isPinned = false
        }
        scheduleSave()
    }

    /// Moves a pinboard to a new index. `index` is expressed against the array *without*
    /// the moved item (i.e. how many other pinboards should sit to its left), so a drag
    /// can pass the count of chips left of the drop point directly. The order persists.
    func movePinboard(_ id: UUID, toIndex index: Int) {
        guard let from = pinboards.firstIndex(where: { $0.id == id }) else { return }
        let moved = pinboards.remove(at: from)
        let clamped = max(0, min(index, pinboards.count))
        pinboards.insert(moved, at: clamped)
        scheduleSave()
    }

    func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        items.removeAll { !$0.isPinned }
        removed.forEach(Self.removeImageFile(for:))
        scheduleSave()
    }

    func matches(query: String, filter: ClipboardSearchFilter = ClipboardSearchFilter()) -> [ClipboardItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = sortedItems

        switch filter.scope {
        case .history:
            break
        case .pinned:
            candidates = candidates.filter(\.isPinned)
        }

        if let kind = filter.kind {
            candidates = candidates.filter { $0.kind == kind }
        }
        if let pinboardID = filter.pinboardID {
            candidates = candidates.filter { $0.pinboardID == pinboardID }
        }
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            $0.text.localizedCaseInsensitiveContains(trimmed) ||
            ($0.title?.localizedCaseInsensitiveContains(trimmed) ?? false) ||
            $0.sourceApp.localizedCaseInsensitiveContains(trimmed) ||
            $0.kind.title.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// Synchronously writes pending changes. Call on app termination so a debounced
    /// save in flight is never lost.
    func flush() {
        // Invalidate any pending debounced write (via generation bump), then write
        // synchronously so the termination snapshot is the authoritative last write.
        saveGeneration &+= 1
        ClipboardStore.writeDocument(currentDocument(), to: fileURL)
    }

    private var sortedItems: [ClipboardItem] {
        items.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private func sortForPins() {
        items = sortedItems
    }

    private func trim() {
        let pinned = items.filter(\.isPinned)
        let unpinned = items.filter { !$0.isPinned }
        let keepCount = max(0, maxItems - pinned.count)
        let kept = Array(unpinned.prefix(keepCount))
        let dropped = Array(unpinned.dropFirst(keepCount))
        items = pinned + kept
        dropped.forEach(Self.removeImageFile(for:))
        sortForPins()
    }

    // MARK: - Persistence

    private func currentDocument() -> StoreDocument {
        StoreDocument(items: items, pinboards: pinboards)
    }

    /// Debounced, off-main persistence. Rapid clipboard activity coalesces into a
    /// single background write instead of blocking the main actor on every change.
    private func scheduleSave() {
        guard !isLoading else { return }
        saveGeneration &+= 1
        let generation = saveGeneration
        let document = currentDocument()
        let url = fileURL
        // Task.detached's operation is @Sendable / non-isolated, so the write runs
        // off the main actor without inheriting MainActor isolation (a DispatchWorkItem
        // closure defined here would inherit it and trip the Swift 6 executor check).
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Skip if a newer change or flush() superseded this debounced write.
            if let self, await self.saveGeneration != generation { return }
            ClipboardStore.writeDocument(document, to: url)
        }
    }

    nonisolated private static func writeDocument(_ document: StoreDocument, to url: URL) {
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
            NSLog("ClipDeck store save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return }

        if let document = try? decoder.decode(StoreDocument.self, from: data) {
            apply(document)
            return
        }
        if let legacy = try? decoder.decode([ClipboardItem].self, from: data) {
            items = legacy
            sortForPins()
            return
        }
        // Unknown / corrupt format: preserve the bytes instead of silently wiping them.
        backupCorruptFile(data: data)
    }

    private func apply(_ document: StoreDocument) {
        items = document.items
        pinboards = document.pinboards
        sortForPins()
    }

    private func backupCorruptFile(data: Data) {
        let suffix = UUID().uuidString.prefix(8)
        let backupURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("history.corrupt-\(suffix).json")
        do {
            try data.write(to: backupURL, options: .atomic)
            NSLog("ClipDeck: history could not be decoded; preserved a backup at \(backupURL.lastPathComponent)")
        } catch {
            NSLog("ClipDeck: history could not be decoded and backup failed: \(error.localizedDescription)")
        }
    }

    private func ensureDefaultPinboards() {
        guard pinboards.isEmpty else { return }
        pinboards = [
            Pinboard(name: String(localized: "Favorites"), colorName: "orange"),
            Pinboard(name: String(localized: "Work"), colorName: "blue"),
            Pinboard(name: String(localized: "Code"), colorName: "purple")
        ]
        scheduleSave()
    }

    nonisolated static func removeImageFile(for item: ClipboardItem) {
        guard let url = item.imageFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes PNG files in the image directory that no item references anymore
    /// (orphans left behind by deletes/trims in prior versions or crashes).
    private func reconcileImageFiles() {
        let directory = AppPaths.imageDirectoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let referenced = Set(items.compactMap(\.imageFileName))
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
