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

@MainActor
final class ClipboardStore: ObservableObject {
    /// Display order is an invariant: pinned first, then newest first. Every mutation re-establishes
    /// it (`sortForPins`), so readers — `ClipSearch`, the panel — never sort.
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var pinboards: [Pinboard] = []

    /// History cap. Overridable without UI via `defaults write io.github.yaoguohh.trove Trove.maxItems 1000`
    /// (clamped to 50…5000); peers default to 30–200, Trove to 500.
    let maxItems: Int
    static let maxItemsDefaultsKey = "Trove.maxItems"
    static let defaultMaxItems = 500

    private let persistence: HistoryPersistence
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
        persistence = HistoryPersistence(fileURL: storeURL ?? AppPaths.historyFileURL)
        let configured = UserDefaults.standard.integer(forKey: Self.maxItemsDefaultsKey)
        maxItems = configured == 0 ? Self.defaultMaxItems : min(5000, max(50, configured))
        load()
        ensureDefaultPinboards()
        if managesSidecarFiles {
            // Thumbnails count as referenced through `thumbnailFileName`.
            HistoryPersistence.removeUnreferencedFiles(
                in: AppPaths.imageDirectoryURL,
                referenced: Set(items.compactMap(\.imageFileName) + items.compactMap(\.thumbnailFileName))
            )
            HistoryPersistence.removeUnreferencedFiles(
                in: AppPaths.textDirectoryURL,
                referenced: Set(items.compactMap(\.textFileName))
            )
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

        // Build the next array locally and publish ONCE: every `items` assignment re-runs the
        // panel's search over the whole history, so an add must not publish three times.
        var next = items
        if let existing {
            // Re-copy of an existing clip: move to the top, refresh source. A big clip's sidecar is
            // already on disk and unchanged, so nothing is rewritten.
            var item = next.remove(at: existing)
            item.createdAt = Date()
            item.sourceApp = sourceApp
            item.sourceBundleIdentifier = sourceBundleIdentifier
            item.sourceAppPath = sourceAppPath
            next.insert(item, at: 0)
        } else {
            let item = makeStoredItem(
                text: text,
                sourceApp: sourceApp,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceAppPath: sourceAppPath,
                normalizedHash: incomingHash
            )
            next.insert(item, at: 0)
        }

        commit(next)
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
            Log.store.error("text sidecar save failed: \(error.localizedDescription, privacy: .public)")
            // Fall back to full inline so paste fidelity is never silently lost; still allow dedup.
            item.fullTextHash = hash
        }
        return item
    }

    /// Synchronous image ingestion (PNG bytes): writes the image + thumbnail, then inserts. The live
    /// monitor prefers `addPreparedImage` with files written off-main; this path serves tests and
    /// callers that already hold the bytes on the main actor.
    func addImage(
        data: Data,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        sourceAppPath: String? = nil
    ) {
        let id = UUID()
        var files = ImageIngest.StoredFiles(imageFileName: ImageIngest.imageFileName(for: id), thumbnailFileName: nil)
        if managesSidecarFiles {
            do {
                files = try ImageIngest.writeFiles(id: id, png: data, directory: ClipboardItem.imageDirectoryURL)
            } catch {
                Log.images.error("image save failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        addPreparedImage(
            id: id,
            files: files,
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceAppPath: sourceAppPath,
            createdAt: Date()
        )
    }

    /// Insert an image clip whose files are already on disk (written by `ImageIngest` on a background
    /// task). `createdAt` is the capture time, so a clip that finished encoding after a later text copy
    /// still sorts into its true position.
    func addPreparedImage(
        id: UUID,
        files: ImageIngest.StoredFiles,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        sourceAppPath: String?,
        createdAt: Date
    ) {
        var item = ClipboardItem(
            id: id,
            text: "Image",
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceAppPath: sourceAppPath,
            imageFileName: files.imageFileName,
            createdAt: createdAt,
            kind: .image,
            title: "Image"
        )
        item.thumbnailFileName = files.thumbnailFileName
        var next = items
        next.insert(item, at: 0)
        commit(next)
    }

    /// One-time migration for image clips stored before thumbnails existed: generate each missing
    /// thumbnail on a utility task (ImageIO downsampling, ~20–130ms per image), then record the file
    /// names and save once. Items whose original is already small point their thumbnail at the
    /// original so they are never re-examined.
    func backfillThumbnails() {
        guard managesSidecarFiles else { return }
        let pending: [(id: UUID, url: URL)] = items.compactMap { item in
            guard item.thumbnailFileName == nil, let url = item.imageFileURL else { return nil }
            return (item.id, url)
        }
        guard !pending.isEmpty else { return }
        let directory = ClipboardItem.imageDirectoryURL
        // Main-actor task awaits the detached work; only the Sendable result crosses back, so no
        // reference to `self` is ever sent off the main actor (Swift 6.0 rejects that).
        Task { [weak self] in
            let resolved = await Self.generateThumbnails(for: pending, in: directory)
            guard !resolved.isEmpty else { return }
            self?.applyThumbnails(resolved)
        }
    }

    nonisolated private static func generateThumbnails(
        for pending: [(id: UUID, url: URL)],
        in directory: URL
    ) async -> [(id: UUID, thumbnailFileName: String)] {
        await Task.detached(priority: .utility) {
            var resolved: [(id: UUID, thumbnailFileName: String)] = []
            for entry in pending {
                guard let png = try? Data(contentsOf: entry.url) else { continue }   // missing file: leave it
                switch ImageIngest.thumbnail(from: png) {
                case .generated(let data):
                    let name = ImageIngest.thumbnailFileName(for: entry.id)
                    guard (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else { continue }
                    resolved.append((entry.id, name))
                case .notNeeded:
                    resolved.append((entry.id, entry.url.lastPathComponent))
                case .failed:
                    continue
                }
            }
            return resolved
        }.value
    }

    private func applyThumbnails(_ resolved: [(id: UUID, thumbnailFileName: String)]) {
        let names = Dictionary(resolved.map { ($0.id, $0.thumbnailFileName) }, uniquingKeysWith: { first, _ in first })
        var next = items
        var changed = false
        for index in next.indices where next[index].thumbnailFileName == nil {
            if let name = names[next[index].id] {
                next[index].thumbnailFileName = name
                changed = true
            }
        }
        guard changed else { return }
        items = next
        scheduleSave()
        Log.images.notice("backfilled \(resolved.count) image thumbnails")
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
        var next = items
        for index in next.indices where next[index].pinboardID == pinboard.id {
            next[index].pinboardID = nil
            next[index].isPinned = false
        }
        // Un-pinning moves cards out of the pinned block, so re-establish the order invariant.
        items = Self.sorted(next)
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

    /// Filter the (already display-ordered) history. The panel keeps its own memoised copy via
    /// `PanelViewModel`; this entry point serves one-off callers (the status menu count, tests).
    func matches(query: String, filter: ClipboardSearchFilter = ClipboardSearchFilter()) -> [ClipboardItem] {
        ClipSearch.filter(items, query: query, filter: filter)
    }

    /// Synchronously writes pending changes. Call on app termination so a debounced
    /// save in flight is never lost.
    func flush() {
        // Invalidate any pending debounced write (via generation bump), then write
        // synchronously so the termination snapshot is the authoritative last write.
        saveGeneration &+= 1
        HistoryPersistence.write(currentDocument(), to: persistence.fileURL)
    }

    nonisolated private static func sorted(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted {
            if $0.isPinned != $1.isPinned {
                return $0.isPinned && !$1.isPinned
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private func sortForPins() {
        items = Self.sorted(items)
    }

    /// Trim to the cap, restore display order and publish `items` exactly once, then persist.
    private func commit(_ next: [ClipboardItem]) {
        let pinned = next.filter(\.isPinned)
        let unpinned = next.filter { !$0.isPinned }
        let keepCount = max(0, maxItems - pinned.count)
        let kept = Array(unpinned.prefix(keepCount))
        let dropped = Array(unpinned.dropFirst(keepCount))
        items = Self.sorted(pinned + kept)
        dropped.forEach(Self.removeImageFile(for:))
        dropped.forEach(Self.removeTextFile(for:))
        scheduleSave()
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
        let url = persistence.fileURL
        // Task.detached's operation is @Sendable / non-isolated, so the write runs
        // off the main actor without inheriting MainActor isolation (a DispatchWorkItem
        // closure defined here would inherit it and trip the Swift 6 executor check).
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Skip if a newer change or flush() superseded this debounced write.
            if let self, await self.saveGeneration != generation { return }
            HistoryPersistence.write(document, to: url)
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        switch persistence.load() {
        case .document(let document):
            items = Self.sorted(document.items)
            pinboards = document.pinboards
        case .legacy(let legacyItems):
            items = Self.sorted(legacyItems)
        case .missing, .corrupt:
            // Corrupt bytes were backed up by `HistoryPersistence`; start empty rather than wipe them.
            break
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
        if let url = item.imageFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        // A small image's thumbnail IS the image (same file); the second remove is a harmless no-op.
        if let url = item.thumbnailFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    nonisolated static func removeTextFile(for item: ClipboardItem) {
        guard let url = item.textFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
