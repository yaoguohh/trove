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
    /// Max characters of a clip's text scanned per item per keystroke. Bounds search to O(cap) so a
    /// huge clip can't make every keystroke walk a multi-MB string. A clip's stored `text` is itself
    /// bounded once the sidecar storage cap ships, but capping the scan independently means a future
    /// change to that cap can't silently re-introduce an unbounded per-keystroke scan. Documented
    /// limitation: a match that occurs ONLY past this prefix (in a clip's sidecar tail) won't surface.
    private let searchScanCap = 20_000
    private let decoder = JSONDecoder()
    private let fileURL: URL
    private let managesSidecarFiles: Bool
    private var isLoading = false
    private var saveGeneration = 0

    /// Cards removed by an explicit user delete, oldest-first; ⌘Z (`undoDelete`) pops the newest back.
    /// In-memory and session-scoped (NOT persisted) — undo recovers an accidental delete within the
    /// session, nothing more. Bounded by `maxUndoDepth` so a long deleting spree can't pin unbounded
    /// memory. `delete` DEFERS removing a clip's sidecar/image files to here: they're removed only when
    /// the clip is evicted past the cap (so until then an undo can restore it byte-for-byte); the
    /// launch-time reconcile is the orphan backstop for anything an abrupt quit strands.
    private var deletedUndoStack: [ClipboardItem] = []
    private let maxUndoDepth = 25

    /// Whether there's a deleted card to restore — drives the panel's ⌘Z gating.
    var canUndoDelete: Bool { !deletedUndoStack.isEmpty }

    /// `storeURL` is injectable so tests can run against a temp file without
    /// touching the user's real Application Support directory.
    init(storeURL: URL? = nil) {
        managesSidecarFiles = (storeURL == nil)
        fileURL = storeURL ?? AppPaths.historyFileURL
        load()
        ensureDefaultPinboards()
        if managesSidecarFiles {
            reconcileImageFiles()
            reconcileTextFiles()
        }
    }

    func add(text: String, sourceApp: String, sourceBundleIdentifier: String? = nil, sourceAppPath: String? = nil) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        // A clip spills to a sidecar when its NORMALIZED (whitespace-trimmed) length exceeds the
        // threshold, and its dedup key is the hash of that NORMALIZED form — so a re-copy that differs
        // only by surrounding whitespace (editors/terminals toggle a trailing newline constantly)
        // hashes identically and dedups, exactly like the small-clip path. Small clips keep the direct
        // normalized comparison. The two predicates are mutually exclusive (hashed vs nil-hash).
        let incomingHash = normalized.count > ClipboardItem.sidecarThreshold ? ClipboardItem.hash(normalized) : nil
        let existing = dedupIndex(hash: incomingHash, normalizedText: normalized)

        if let existing {
            // Re-copy of an existing clip: move to the top, refresh source. A big clip's sidecar is
            // already on disk and unchanged, so nothing is rewritten.
            var item = items.remove(at: existing)
            item.createdAt = Date()
            item.sourceApp = sourceApp
            item.sourceBundleIdentifier = sourceBundleIdentifier
            item.sourceAppPath = sourceAppPath
            items.insert(item, at: 0)
        } else {
            let item = makeStoredItem(
                text: text,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceAppPath: sourceAppPath,
                normalizedHash: incomingHash
            )
            items.insert(item, at: 0)
        }

        trim()
        scheduleSave()
    }

    /// Index of an existing live clip that dedups against the given content — by `fullTextHash` for a
    /// spilled clip, else by normalized-text equality. Shared by `add` (ingestion) and `undoDelete`
    /// (so a restore can't re-create a duplicate of a clip that was re-copied while it sat on the undo
    /// stack), keeping the single-card-per-content invariant in one place.
    private func dedupIndex(hash: String?, normalizedText: String) -> Int? {
        items.firstIndex {
            if let hash { return $0.fullTextHash == hash }
            return $0.fullTextHash == nil
                && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
        }
    }

    /// Builds a clip applying the hybrid storage cap. A clip whose NORMALIZED length is within
    /// `sidecarThreshold` is stored verbatim inline (the common path — byte-faithful, no IO). Above it,
    /// the verbatim full text spills to a sidecar `.txt` and only the `inlineTextCap` prefix stays in
    /// `history.json`. Independently, any text past `ultimateSidecarCeiling` (verbatim) is hard-
    /// truncated and flagged, bounding even a pathological all-whitespace paste.
    /// `normalizedHash` (non-nil iff the clip spills) is the precomputed dedup key.
    private func makeStoredItem(
        text: String,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        sourceAppPath: String?,
        normalizedHash: String?
    ) -> ClipboardItem {
        var storedText = text
        var truncated = false
        if text.count > ClipboardItem.ultimateSidecarCeiling {
            storedText = String(text.prefix(ClipboardItem.ultimateSidecarCeiling))
            truncated = true
        }

        var item = ClipboardItem(
            text: storedText,
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceAppPath: sourceAppPath,
            // Kind is display-only (icon/label); detect from a bounded prefix so a multi-MB paste
            // doesn't scan the whole string several times on the main-thread ingestion path.
            kind: ClipboardItem.detectKind(for: String(storedText.prefix(ClipboardItem.displayPreviewCap)))
        )
        if truncated {
            // Surface the TRUE original size and mark the clip; paste can't include the lost tail.
            item.isTruncated = true
            item.characterCount = text.count
            item.originalCharacterCount = text.count
        }

        // Spill iff the clip is big by normalized length (== normalizedHash is set).
        guard let hash = normalizedHash else { return item }

        guard managesSidecarFiles else {
            // Injected/test store: no sidecar directory to own. Keep the full text inline but still
            // record the hash so big-clip dedup is exercised in tests.
            item.fullTextHash = hash
            return item
        }

        let fileName = "\(item.id.uuidString).txt"
        do {
            try FileManager.default.createDirectory(at: ClipboardItem.textDirectoryURL, withIntermediateDirectories: true)
            // The sidecar is written SYNCHRONOUSLY and atomically BEFORE the item enters the array /
            // history.json. This is deliberate: it guarantees that whenever a persisted item references
            // a sidecar, that sidecar exists on disk — so `fullText` (paste/copy/drag fidelity) never
            // races a pending write, and a crash leaves at most an orphan .txt (swept by
            // reconcileTextFiles on launch), never a dangling reference. The cost is a one-time O(n)
            // write proportional to clip size, on a deliberate copy of unusual (>20k-char) content —
            // acceptable, and unlike the old per-render hang it does not repeat.
            try Data(storedText.utf8).write(to: ClipboardItem.textDirectoryURL.appendingPathComponent(fileName), options: .atomic)
            item.fullTextHash = hash
            item.textFileName = fileName
            item.text = String(storedText.prefix(ClipboardItem.inlineTextCap))
        } catch {
            NSLog("Trove text sidecar save failed: \(error.localizedDescription)")
            // Fall back to full inline so paste fidelity is never silently lost; still allow dedup.
            item.fullTextHash = hash
        }
        return item
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
            NSLog("Trove image save failed: \(error.localizedDescription)")
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
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        // Capture the store's canonical copy and push it to the undo stack. Its sidecar/image files are
        // intentionally NOT removed here — `pushUndo` removes them only on eviction, so ⌘Z can restore
        // the clip with full fidelity until then.
        let removed = items.remove(at: index)
        pushUndo(removed)
        scheduleSave()
    }

    /// Push a just-deleted clip onto the bounded undo stack, removing the files of anything evicted
    /// past the cap (the removal `delete` deferred). Eviction is the point of no return for a delete.
    private func pushUndo(_ item: ClipboardItem) {
        deletedUndoStack.append(item)
        while deletedUndoStack.count > maxUndoDepth {
            let evicted = deletedUndoStack.removeFirst()
            Self.removeImageFile(for: evicted)
            Self.removeTextFile(for: evicted)
        }
    }

    /// Restore the most recently deleted clip (⌘Z), returning it so the caller can re-select the card.
    /// The clip re-enters at its original time-sorted slot (it kept its `createdAt` — an honest copy
    /// timestamp, never rewritten); its files were never removed by `delete`, so fidelity is intact.
    /// Returns nil when there's nothing to undo.
    ///
    /// Deliberately does NOT `trim()`: a `delete` already freed a slot, so a restore returns the history
    /// to at most its cap — it never overflows here. Known limitation: at a FULL history, undoing the
    /// OLDEST clip puts it back at the bottom, where the next `add` ages it out by normal LRU (its files
    /// are then removed cleanly). Pin a recovered clip to keep it; rewriting `createdAt` to dodge this
    /// would lie about when the clip was copied, which the card's relative-time display relies on.
    @discardableResult
    func undoDelete() -> ClipboardItem? {
        guard var item = deletedUndoStack.popLast() else { return nil }

        // The clip carried its pin state onto the stack; if its pinboard was deleted while it sat there,
        // restore it loose rather than dangling-pinned (a card referencing a gone board is invisible to
        // every live pinboard filter). Validating on restore covers ANY structural mutation, not just
        // deletePinboard.
        if let boardID = item.pinboardID, !pinboards.contains(where: { $0.id == boardID }) {
            item.pinboardID = nil
            item.isPinned = false
        }

        // If the content is already live (the user re-copied it after deleting), don't create a
        // duplicate. Discard the stale undo entry and its now-redundant sidecar/image files, surfacing
        // the existing card instead — the same single-card-per-content guarantee `add` makes.
        let normalized = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existingIndex = dedupIndex(hash: item.fullTextHash, normalizedText: normalized) {
            Self.removeImageFile(for: item)
            Self.removeTextFile(for: item)
            return items[existingIndex]
        }

        items.append(item)
        sortForPins()
        scheduleSave()
        return item
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

    /// Record that a clip was just pasted from the panel by stamping `lastUsedAt`. This is currently
    /// kept as raw data for a future opt-in "Most Used" mode — nothing reads it yet — so it deliberately
    /// does NOT `scheduleSave()`: persisting on every paste would re-encode the whole history document
    /// for a field no code consumes. The in-memory value is up to date for any same-session reader, and
    /// it is durably written by the next real mutation's save or the quit-time `flush()`. Operates on
    /// metadata only — never reads `fullText`, never reorders the timeline.
    func recordUse(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].lastUsedAt = Date()
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
        removed.forEach(Self.removeTextFile(for:))
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
            // `prefix(_:)` is O(searchScanCap); scanning only the bounded prefix keeps each keystroke
            // cheap regardless of clip size. (`localizedCaseInsensitiveContains` bridges the prefix to
            // NSString — a small, capped ≤searchScanCap copy per item, not the whole clip.)
            $0.text.prefix(searchScanCap).localizedCaseInsensitiveContains(trimmed) ||
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
        dropped.forEach(Self.removeTextFile(for:))
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
            NSLog("Trove store save failed: \(error.localizedDescription)")
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
            NSLog("Trove: history could not be decoded; preserved a backup at \(backupURL.lastPathComponent)")
        } catch {
            NSLog("Trove: history could not be decoded and backup failed: \(error.localizedDescription)")
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

    nonisolated static func removeTextFile(for item: ClipboardItem) {
        guard let url = item.textFileURL else { return }
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

    /// Deletes sidecar `.txt` files no item references anymore (orphans from a crash between the
    /// sidecar write and the history persist, or from deletes/trims in a prior run).
    private func reconcileTextFiles() {
        let directory = AppPaths.textDirectoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let referenced = Set(items.compactMap(\.textFileName))
        for file in files where !referenced.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }
}
