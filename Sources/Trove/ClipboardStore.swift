import Foundation

/// The panel's scope chips: an optional kind and an optional pinboard (nil = everything).
struct ClipboardSearchFilter: Equatable {
    var kind: ClipboardKind?
    var pinboardID: UUID?
}

@MainActor
final class ClipboardStore: ObservableObject {
    /// Display order is an invariant: pinned first, then newest first. Every mutation re-establishes
    /// it (`sortForPins`), so readers — `ClipSearch`, the panel — never sort.
    @Published private(set) var items: [ClipboardItem] = []
    @Published private(set) var pinboards: [Pinboard] = []

    /// History cap for unpinned clips (`AppSettings.maxItems`); pinned clips never age out.
    let maxItems: Int

    /// Where this history's files live. The app uses `.live`; tests inject a temporary root.
    let files: ClipFiles
    private let persistence: HistoryPersistence
    private let writer: HistoryWriter
    private var needsMigrationSave = false
    /// Set when `history.json` exists but could not be read: saving would overwrite it with an empty
    /// history, so nothing is written this session.
    private var savingDisabled = false

    /// Cards removed by an explicit user delete, oldest-first; ⌘Z (`undoDelete`) pops the newest back.
    /// In-memory and session-scoped (NOT persisted) — undo recovers an accidental delete within the
    /// session, nothing more. Bounded by `maxUndoDepth` so a long deleting spree can't pin unbounded
    /// memory. `delete` DEFERS removing a clip's sidecar/image files to here: they're removed only when
    /// the clip is evicted past the cap (so until then an undo can restore it byte-for-byte); the
    /// launch-time orphan sweep is the backstop for anything an abrupt quit strands.
    private var deletedUndoStack: [ClipboardItem] = []
    private let maxUndoDepth = 25

    /// Whether there's a deleted card to restore — drives the panel's ⌘Z gating.
    var canUndoDelete: Bool { !deletedUndoStack.isEmpty }

    init(files: ClipFiles = .live, maxItems: Int = AppSettings.defaultMaxItems) {
        self.files = files
        persistence = HistoryPersistence(fileURL: files.historyFile)
        writer = HistoryWriter(fileURL: files.historyFile)
        self.maxItems = maxItems
        load()
        if needsMigrationSave {
            scheduleSave()
        }
        ensureDefaultPinboards()
        guard !savingDisabled else { return }
        // Launch-time orphan sweep: files no clip references (a crash between a sidecar write and the
        // history save, or deletes by older versions). Thumbnails count as referenced too.
        HistoryPersistence.removeUnreferencedFiles(
            in: files.imageDirectory,
            referenced: Set(items.compactMap(\.imageFileName) + items.compactMap(\.thumbnailFileName))
        )
        HistoryPersistence.removeUnreferencedFiles(
            in: files.textDirectory,
            referenced: Set(items.compactMap(\.textFileName))
        )
    }

    func add(text: String, sourceApp: String, sourceBundleIdentifier: String? = nil, sourceAppPath: String? = nil) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        // Spilling to a sidecar is decided on the same normalized length the identity is built from.
        let identity = ClipboardItem.textIdentity(normalized)

        // Build the next array locally and publish ONCE: every `items` assignment re-runs the
        // panel's search over the whole history, so an add must not publish three times.
        var next = items
        if let existing = dedupIndex(contentHash: identity) {
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
                contentHash: identity,
                spills: normalized.count > ClipboardItem.sidecarThreshold
            )
            next.insert(item, at: 0)
        }

        commit(next)
    }

    /// Index of the live clip with this content identity. Shared by `add`, `addPreparedImage` and
    /// `undoDelete` (so a restore can't re-create a duplicate of a clip that was re-copied while it sat
    /// on the undo stack), keeping the one-card-per-content invariant in one place. A nil identity
    /// (a legacy image) matches nothing.
    private func dedupIndex(contentHash: String?) -> Int? {
        guard let contentHash else { return nil }
        return items.firstIndex { $0.contentHash == contentHash }
    }

    /// Builds a clip applying the hybrid storage cap. A clip whose NORMALIZED length is within
    /// `sidecarThreshold` is stored verbatim inline (the common path — byte-faithful, no IO). Above it,
    /// the verbatim full text spills to a sidecar `.txt` and only the `inlineTextCap` prefix stays in
    /// `history.json`. Independently, any text past `ultimateSidecarCeiling` (verbatim) is hard-
    /// truncated and flagged, bounding even a pathological all-whitespace paste.
    /// `contentHash` is the precomputed identity; `spills` says whether the normalized text is over
    /// the sidecar threshold.
    private func makeStoredItem(
        text: String,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        sourceAppPath: String?,
        contentHash: String,
        spills: Bool
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
            kind: ClipboardItem.detectKind(for: String(storedText.prefix(ClipboardItem.displayPreviewCap))),
            contentHash: contentHash
        )
        if truncated {
            // Surface the TRUE original size and mark the clip; paste can't include the lost tail.
            item.isTruncated = true
            item.characterCount = text.count
            item.originalCharacterCount = text.count
        }

        guard spills else { return item }

        do {
            // The sidecar is written SYNCHRONOUSLY and atomically BEFORE the item enters the array /
            // history.json. This is deliberate: it guarantees that whenever a persisted item references
            // a sidecar, that sidecar exists on disk — so `ClipFiles.fullText` (paste/copy/drag) never
            // races a pending write, and a crash leaves at most an orphan .txt (swept by
            // the launch-time orphan sweep), never a dangling reference. The cost is a one-time O(n)
            // write proportional to clip size, on a deliberate copy of unusual (>20k-char) content.
            item.textFileName = try files.writeText(storedText, for: item.id)
            item.text = String(storedText.prefix(ClipboardItem.inlineTextCap))
        } catch {
            // Fall back to full inline so paste fidelity is never silently lost.
            Log.store.error("text sidecar save failed: \(error.localizedDescription, privacy: .public)")
        }
        return item
    }

    /// Synchronous image ingestion (PNG bytes): writes the image + thumbnail, then inserts. The live
    /// monitor uses `addPreparedImage` with files written off-main; this path serves tests.
    func addImage(
        data: Data,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        sourceAppPath: String? = nil
    ) {
        let id = UUID()
        let stored: ImageIngest.StoredFiles
        do {
            stored = try ImageIngest.writeFiles(id: id, png: data, directory: files.imageDirectory)
        } catch {
            Log.images.error("image save failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        addPreparedImage(
            id: id,
            files: stored,
            contentHash: ClipboardItem.hash(data),
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceAppPath: sourceAppPath,
            createdAt: Date()
        )
    }

    /// Insert an image clip whose files are already on disk (written by `ImageIngest` on a background
    /// task). `createdAt` is the capture time, so a clip that finished encoding after a later text copy
    /// still sorts into its true position. `contentHash` is the hash of the stored PNG bytes; a
    /// re-copy of an image already in history moves that card up and drops the just-written files.
    func addPreparedImage(
        id: UUID,
        files: ImageIngest.StoredFiles,
        contentHash: String,
        sourceApp: String,
        sourceBundleIdentifier: String?,
        sourceAppPath: String?,
        createdAt: Date
    ) {
        var item = ClipboardItem(
            id: id,
            text: "",
            sourceApp: sourceApp,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceAppPath: sourceAppPath,
            imageFileName: files.imageFileName,
            createdAt: createdAt,
            kind: .image,
            contentHash: contentHash
        )
        item.thumbnailFileName = files.thumbnailFileName
        var next = items
        if let existing = dedupIndex(contentHash: contentHash) {
            self.files.removeFiles(of: item)
            var kept = next.remove(at: existing)
            kept.createdAt = createdAt
            kept.sourceApp = sourceApp
            kept.sourceBundleIdentifier = sourceBundleIdentifier
            kept.sourceAppPath = sourceAppPath
            next.insert(kept, at: 0)
        } else {
            next.insert(item, at: 0)
        }
        commit(next)
    }

    /// One-time migration for image clips stored before thumbnails existed (v1.1.x): generate each missing
    /// thumbnail on a utility task (ImageIO downsampling, ~20–130ms per image), then record the file
    /// names and save once. Items whose original is already small point their thumbnail at the
    /// original so they are never re-examined.
    /// TODO(v1.5): remove, with its launch-time call in AppDelegate, once upgrades straight from v1.1.x
    /// are no longer expected.
    func backfillThumbnails() {
        let pending: [(id: UUID, url: URL)] = items.compactMap { item in
            guard item.thumbnailFileName == nil, let url = files.imageURL(for: item) else { return nil }
            return (item.id, url)
        }
        guard !pending.isEmpty else { return }
        let directory = files.imageDirectory
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
        guard let index = index(of: item) else { return }
        items[index].isPinned.toggle()
        if !items[index].isPinned {
            items[index].pinboardID = nil
        }
        sortForPins()
        scheduleSave()
    }

    func delete(_ item: ClipboardItem) {
        guard let index = index(of: item) else { return }
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
            files.removeFiles(of: deletedUndoStack.removeFirst())
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
        if let existingIndex = dedupIndex(contentHash: item.contentHash) {
            files.removeFiles(of: item)
            return items[existingIndex]
        }

        items.append(item)
        sortForPins()
        scheduleSave()
        return item
    }

    func move(_ item: ClipboardItem, to pinboard: Pinboard?) {
        guard let index = index(of: item) else { return }
        items[index].pinboardID = pinboard?.id
        items[index].isPinned = pinboard != nil
        sortForPins()
        scheduleSave()
    }

    /// Set or clear a clip's custom display name (shown in the card header; also searchable). An
    /// empty/nil name reverts the card to its kind label.
    func rename(_ item: ClipboardItem, to title: String?) {
        guard let index = index(of: item) else { return }
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
        removed.forEach(files.removeFiles(of:))
        scheduleSave()
    }

    /// Synchronously writes the current history, superseding any pending debounced save. Called on
    /// app termination so the last change is never lost.
    func flush() {
        guard !savingDisabled else { return }
        writer.flush(currentDocument())
    }

    private func index(of item: ClipboardItem) -> Int? {
        items.firstIndex { $0.id == item.id }
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
        dropped.forEach(files.removeFiles(of:))
        scheduleSave()
    }

    // MARK: - Persistence

    private func currentDocument() -> StoreDocument {
        StoreDocument(items: items, pinboards: pinboards)
    }

    /// Debounced, off-main persistence: rapid clipboard activity coalesces into a single background
    /// write instead of blocking the main actor on every change.
    private func scheduleSave() {
        guard !savingDisabled else { return }
        writer.schedule(currentDocument())
    }

    private func load() {
        switch persistence.load() {
        case .document(let document):
            items = Self.sorted(document.items)
            pinboards = document.pinboards
            // Items migrate while decoding; write the upgraded document back so it happens once.
            needsMigrationSave = document.version < StoreDocument.currentVersion
        case .missing, .corrupt:
            // Corrupt bytes were backed up by `HistoryPersistence`; start empty rather than wipe them.
            break
        case .unreadable:
            savingDisabled = true
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
}
