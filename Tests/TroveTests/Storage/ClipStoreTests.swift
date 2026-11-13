import Foundation
import Combine
import Testing
@testable import Trove

@MainActor
struct ClipStoreDedupTests {
    @Test func dedupesIgnoringSurroundingWhitespace() {
        let (store, _) = makeTempStore()
        store.add(text: "foo", sourceApp: "X")
        store.add(text: "  foo  ", sourceApp: "X")
        store.add(text: "foo\n", sourceApp: "X")
        #expect(store.items.count == 1)
    }

    @Test func keepsDistinctTexts() {
        let (store, _) = makeTempStore()
        store.add(text: "foo", sourceApp: "X")
        store.add(text: "bar", sourceApp: "X")
        #expect(store.items.count == 2)
    }
}

@MainActor
struct ClipStoreMutationTests {
    @Test func deleteRemovesItem() {
        let (store, _) = makeTempStore()
        store.add(text: "a", sourceApp: "X")
        let item = store.items[0]

        store.delete(item)
        #expect(store.items.isEmpty)
    }

    @Test func clearUnpinnedKeepsPinned() {
        let (store, _) = makeTempStore()
        store.add(text: "keep", sourceApp: "X")
        store.add(text: "drop", sourceApp: "X")
        store.togglePin(store.items.first { $0.text == "keep" }!)

        store.clearUnpinned()
        #expect(store.items.count == 1)
        #expect(store.items.first?.text == "keep")
    }
}

@MainActor
struct ClipStoreUndoDeleteTests {
    @Test func deleteThenUndoRestoresItem() {
        let (store, _) = makeTempStore()
        store.add(text: "alpha", sourceApp: "X")
        let item = store.items[0]
        store.delete(item)
        #expect(store.items.contains { $0.id == item.id } == false)

        let restored = store.undoDelete()
        #expect(restored?.id == item.id)
        #expect(store.items.contains { $0.id == item.id })
    }

    @Test func undoRestoresOriginalTimeOrderNotTop() {
        let (store, _) = makeTempStore()
        store.add(text: "first", sourceApp: "X")
        store.add(text: "second", sourceApp: "X")
        store.add(text: "third", sourceApp: "X") // newest-first: third, second, first
        let middle = store.items[1]              // "second"
        store.delete(middle)
        _ = store.undoDelete()
        // It re-enters by its own createdAt (the middle), not at the top.
        #expect(store.items.map(\.text) == ["third", "second", "first"])
    }

    @Test func multiLevelUndoPopsNewestDeleteFirst() {
        let (store, _) = makeTempStore()
        store.add(text: "a", sourceApp: "X")
        store.add(text: "b", sourceApp: "X")
        let a = store.items.first { $0.text == "a" }!
        let b = store.items.first { $0.text == "b" }!
        store.delete(a)
        store.delete(b) // undo stack (oldest→newest): [a, b]
        #expect(store.undoDelete()?.id == b.id)
        #expect(store.undoDelete()?.id == a.id)
        #expect(store.undoDelete() == nil)
    }

    @Test func canUndoDeleteReflectsStack() {
        let (store, _) = makeTempStore()
        #expect(store.canUndoDelete == false)
        store.add(text: "x", sourceApp: "X")
        store.delete(store.items[0])
        #expect(store.canUndoDelete)
        _ = store.undoDelete()
        #expect(store.canUndoDelete == false)
    }

    @Test func undoOnEmptyStackReturnsNil() {
        let (store, _) = makeTempStore()
        #expect(store.undoDelete() == nil)
    }

    @Test func undoPreservesPinnedState() {
        let (store, _) = makeTempStore()
        store.add(text: "p", sourceApp: "X")
        store.togglePin(store.items[0])
        let pinned = store.items.first { $0.text == "p" }!
        #expect(pinned.isPinned)
        store.delete(pinned)
        let restored = store.undoDelete()
        #expect(restored?.isPinned == true)
        #expect(store.items.first { $0.id == pinned.id }?.isPinned == true)
    }

    @Test func undoStackIsBoundedToMaxDepth() {
        let (store, _) = makeTempStore()
        for i in 0..<30 { store.add(text: "n\(i)", sourceApp: "X") }
        for item in store.items { store.delete(item) } // 30 deletes; stack caps at 25
        var undone = 0
        while store.undoDelete() != nil { undone += 1 }
        #expect(undone == 25)
    }

    @Test func undoDoesNotDuplicateAReCopiedClip() {
        let (store, _) = makeTempStore()
        store.add(text: "hello", sourceApp: "X")
        let x = store.items[0]
        store.delete(x)
        store.add(text: "hello", sourceApp: "X") // re-copied while x sits on the undo stack
        #expect(store.items.count == 1)

        let restored = store.undoDelete()
        // No duplicate card: undo surfaces the existing live clip instead of re-inserting x.
        #expect(store.items.filter { $0.text == "hello" }.count == 1)
        #expect(restored?.text == "hello")
    }

    @Test func undoDropsPinboardWhenBoardWasDeleted() {
        let (store, _) = makeTempStore()
        store.add(text: "p", sourceApp: "X")
        let board = store.pinboards[0]
        store.move(store.items[0], to: board) // pin onto a board
        let pinned = store.items.first { $0.text == "p" }!
        #expect(pinned.pinboardID == board.id)

        store.delete(pinned)
        store.deletePinboard(board) // board gone while the clip is on the undo stack
        let restored = store.undoDelete()
        // Restored loose, not dangling-pinned to a board that no longer exists.
        #expect(restored?.pinboardID == nil)
        #expect(restored?.isPinned == false)
    }
}

@MainActor
struct ClipStorePinboardReorderTests {
    // Default seeded order is [Favorites, Work, Code].
    @Test func movesToEnd() {
        let (store, _) = makeTempStore()
        let ids = store.pinboards.map(\.id)
        store.movePinboard(ids[0], toIndex: 2)
        #expect(store.pinboards.map(\.id) == [ids[1], ids[2], ids[0]])
    }

    @Test func movesToStart() {
        let (store, _) = makeTempStore()
        let ids = store.pinboards.map(\.id)
        store.movePinboard(ids[2], toIndex: 0)
        #expect(store.pinboards.map(\.id) == [ids[2], ids[0], ids[1]])
    }

    @Test func movingToSameIndexKeepsOrder() {
        let (store, _) = makeTempStore()
        let before = store.pinboards.map(\.id)
        store.movePinboard(before[1], toIndex: 1)
        #expect(store.pinboards.map(\.id) == before)
    }

    @Test func clampsOutOfRangeIndex() {
        let (store, _) = makeTempStore()
        let ids = store.pinboards.map(\.id)
        store.movePinboard(ids[0], toIndex: 99)
        #expect(store.pinboards.map(\.id) == [ids[1], ids[2], ids[0]])
    }
}

@MainActor
struct ClipStoreLoadTests {
    @Test func corruptFileIsBackedUpNotSilentlyWiped() throws {
        let dir = makeTempDirectory()
        let url = dir.appendingPathComponent("history.json")
        let corruptBytes = Data("this is not valid json".utf8)
        try corruptBytes.write(to: url)

        _ = ClipStore(files: ClipFiles(root: url.deletingLastPathComponent()))

        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let backups = siblings.filter { $0.contains("corrupt") }
        #expect(!backups.isEmpty)
        // The original corrupt bytes must survive somewhere (not destroyed).
        let backupURL = dir.appendingPathComponent(backups[0])
        #expect((try? Data(contentsOf: backupURL)) == corruptBytes)
    }

    @Test func missingFileLoadsCleanlyWithDefaults() {
        let (store, _) = makeTempStore()
        #expect(store.items.isEmpty)
        #expect(!store.pinboards.isEmpty) // default pinboards seeded
    }
}

// Each test store owns a temporary root, so big clips really spill to `texts/` there.
@MainActor
struct ClipStoreSidecarTests {
    @Test func subThresholdStoresVerbatimNoSidecar() {
        let (store, _) = makeTempStore()
        store.add(text: "small clip", sourceApp: "X")
        let item = store.items[0]
        #expect(item.textFileName == nil)
        #expect(item.contentHash == Clip.textIdentity("small clip"))
        #expect(store.files.fullText(of: item) == "small clip")
        #expect(item.isTruncated == false)
        #expect(item.characterCount == 10)
    }

    @Test func aboveCeilingTruncatesAndFlags() {
        let (store, _) = makeTempStore()
        let original = Clip.ultimateSidecarCeiling + 100
        store.add(text: String(repeating: "a", count: original), sourceApp: "X")
        let item = store.items[0]
        #expect(store.files.fullText(of: item).count == Clip.ultimateSidecarCeiling)
        #expect(item.isTruncated == true)
        #expect(item.originalCharacterCount == original)
        #expect(item.characterCount == original) // footer shows the TRUE source length
    }

    @Test func dedupBigClipByContent() {
        let (store, _) = makeTempStore()
        let big = String(repeating: "z", count: Clip.sidecarThreshold + 500)
        store.add(text: big, sourceApp: "X")
        store.add(text: big, sourceApp: "Y")
        #expect(store.items.count == 1)
        #expect(store.items[0].contentHash == Clip.textIdentity(big))
    }

    @Test func bigClipDedupsAcrossSurroundingWhitespace() {
        // The P1 fix: dedup key is the hash of the NORMALIZED form, so a re-copy that differs only by
        // surrounding whitespace (a toggled trailing newline) dedups instead of writing a 2nd entry.
        let (store, _) = makeTempStore()
        let big = String(repeating: "q", count: Clip.sidecarThreshold + 500)
        store.add(text: big, sourceApp: "X")
        store.add(text: "  " + big + "\n", sourceApp: "Y")
        #expect(store.items.count == 1)
    }

    @Test func dedupKeepsDistinctBigClips() {
        let (store, _) = makeTempStore()
        let base = String(repeating: "z", count: Clip.sidecarThreshold + 500)
        store.add(text: base + "ONE", sourceApp: "X")
        store.add(text: base + "TWO", sourceApp: "X")
        #expect(store.items.count == 2)
    }

    @Test func dedupBoundaryCrossingThreshold() {
        let (store, _) = makeTempStore()
        store.add(text: "short", sourceApp: "X")
        store.add(text: String(repeating: "z", count: Clip.sidecarThreshold + 500), sourceApp: "X")
        // A small and a big clip have different identities and never false-match.
        #expect(store.items.count == 2)
    }

    @Test func smallClipWhitespaceDedupStillPasses() {
        let (store, _) = makeTempStore()
        store.add(text: "foo", sourceApp: "X")
        store.add(text: "  foo  ", sourceApp: "X")
        #expect(store.items.count == 1)
    }
}

@MainActor
struct ClipStoreFileLifecycleTests {
    @Test func launchSweepRemovesOrphanedFiles() throws {
        let (store, url) = makeTempStore()
        store.add(text: String(repeating: "k", count: Clip.sidecarThreshold + 1), sourceApp: "X")
        store.flush()
        let kept = try #require(store.files.textURL(for: store.items[0]))
        let orphan = store.files.textDirectory.appendingPathComponent("orphan.txt")
        try Data("x".utf8).write(to: orphan)

        let reloaded = ClipStore(files: ClipFiles(root: url.deletingLastPathComponent()))

        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(reloaded.items.count == 1)
    }

    @Test func deleteKeepsFilesUntilUndoIsNoLongerPossible() throws {
        let (store, _) = makeTempStore()
        store.addImage(data: Data("first png".utf8), sourceApp: "X")
        let first = store.items[0]
        let image = try #require(store.files.imageURL(for: first))
        store.delete(first)
        #expect(FileManager.default.fileExists(atPath: image.path))   // undo can still restore it

        // Push the deleted clip past the undo depth.
        for index in 0..<30 {
            store.add(text: "filler \(index)", sourceApp: "X")
            store.delete(store.items[0])
        }
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test func clearUnpinnedRemovesTheirFiles() throws {
        let (store, _) = makeTempStore()
        store.addImage(data: Data("png".utf8), sourceApp: "X")
        let image = try #require(store.files.imageURL(for: store.items[0]))
        store.clearUnpinned()
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }

    @Test func unreadableHistoryIsNeverOverwritten() throws {
        let dir = makeTempDirectory()
        // A directory where the file should be: it "exists" but can't be read as data.
        let historyPath = dir.appendingPathComponent("history.json", isDirectory: true)
        try FileManager.default.createDirectory(at: historyPath, withIntermediateDirectories: true)

        let store = ClipStore(files: ClipFiles(root: dir))
        store.add(text: "new", sourceApp: "X")
        store.flush()

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: historyPath.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

@MainActor
struct ClipStoreOrderInvariantTests {
    @Test func deletePinboardRestoresDisplayOrder() {
        let (store, _) = makeTempStore()
        store.add(text: "oldest", sourceApp: "X")
        store.add(text: "middle", sourceApp: "X")
        store.add(text: "newest", sourceApp: "X")
        let board = store.pinboards[0]
        let oldest = store.items.first { $0.text == "oldest" }!
        store.move(oldest, to: board)
        #expect(store.items.first?.text == "oldest")   // pinned block leads

        store.deletePinboard(board)
        // Un-pinned → back into the time-ordered block, newest first. `ClipSearch` relies on this.
        #expect(store.items.map(\.text) == ["newest", "middle", "oldest"])
    }

    @Test func addPublishesItemsExactlyOnce() {
        let (store, _) = makeTempStore()
        var emissions = 0
        let subscription = store.$items.sink { _ in emissions += 1 }
        defer { subscription.cancel() }
        #expect(emissions == 1)   // the current value on subscribe

        store.add(text: "one publish, not three", sourceApp: "X")
        #expect(emissions == 2)

        store.addPreparedImage(
            id: UUID(),
            files: ImageFiles.StoredFiles(imageFileName: "x.png", thumbnailFileName: nil),
            contentHash: "x",
            sourceApp: "X", sourceBundleIdentifier: nil, sourceAppPath: nil, createdAt: Date()
        )
        #expect(emissions == 3)
    }

    @Test func preparedImageSortsByCaptureTime() {
        let (store, _) = makeTempStore()
        let captured = Date()
        store.add(text: "copied after the screenshot", sourceApp: "X")
        // The image finished encoding after the text arrived, but was captured before it.
        store.addPreparedImage(
            id: UUID(),
            files: ImageFiles.StoredFiles(imageFileName: "shot.png", thumbnailFileName: "shot.thumb.png"),
            contentHash: "shot",
            sourceApp: "X", sourceBundleIdentifier: nil, sourceAppPath: nil, createdAt: captured
        )
        #expect(store.items.map(\.kind) == [.text, .image])
        #expect(store.items[1].thumbnailFileName == "shot.thumb.png")
    }

    @Test func thumbnailFileNameRoundTripsThroughHistoryJSON() throws {
        let (store, url) = makeTempStore()
        store.addPreparedImage(
            id: UUID(),
            files: ImageFiles.StoredFiles(imageFileName: "a.png", thumbnailFileName: "a.thumb.png"),
            contentHash: "a",
            sourceApp: "X", sourceBundleIdentifier: nil, sourceAppPath: nil, createdAt: Date()
        )
        store.flush()
        let reloaded = ClipStore(files: ClipFiles(root: url.deletingLastPathComponent()))
        #expect(reloaded.items.first?.thumbnailFileName == "a.thumb.png")
    }
}

@MainActor
struct ClipStoreContentIdentityTests {
    private func addImage(_ store: ClipStore, bytes: String) {
        store.addImage(data: Data(bytes.utf8), sourceApp: "X")
    }

    @Test func undoRestoresTheDeletedImageNotAnother() throws {
        let (store, _) = makeTempStore()
        addImage(store, bytes: "png A")
        addImage(store, bytes: "png B")
        let imageA = try #require(store.items.first { $0.contentHash == Clip.hash(Data("png A".utf8)) })

        store.delete(imageA)
        let restored = store.undoDelete()

        #expect(restored?.id == imageA.id)
        #expect(store.items.count == 2)
        #expect(store.items.contains { $0.id == imageA.id })
    }

    @Test func textReadingImageCoexistsWithAnImage() {
        let (store, _) = makeTempStore()
        addImage(store, bytes: "png")
        store.add(text: "Image", sourceApp: "X")

        #expect(store.items.count == 2)
        #expect(store.items.map(\.kind) == [.text, .image])
    }

    @Test func recopyingTheSameImageMovesItsCardUp() {
        let (store, _) = makeTempStore()
        addImage(store, bytes: "same png")
        store.add(text: "later text", sourceApp: "X")
        addImage(store, bytes: "same png")

        #expect(store.items.count == 2)
        #expect(store.items.first?.kind == .image)
    }

    @Test func imageClipsStoreNoPlaceholderText() {
        let (store, _) = makeTempStore()
        addImage(store, bytes: "png")
        #expect(store.items[0].text.isEmpty)
        #expect(store.items[0].title == nil)
        #expect(store.items[0].displayTitle == ClipKind.image.title)
    }

    @Test func versionOneDocumentMigrates() throws {
        let dir = makeTempDirectory()
        let url = dir.appendingPathComponent("history.json")
        let legacy = """
        {"items":[\
        {"id":"\(UUID().uuidString)","text":"Image","title":"Image","sourceApp":"X","createdAt":700000002,"isPinned":false,"kind":"image","imageFileName":"a.png","characterCount":0,"isTruncated":false,"originalCharacterCount":0},\
        {"id":"\(UUID().uuidString)","text":" hi ","sourceApp":"X","createdAt":700000001,"isPinned":false,"kind":"text","characterCount":4,"isTruncated":false,"originalCharacterCount":4},\
        {"id":"\(UUID().uuidString)","text":"big prefix","sourceApp":"X","createdAt":700000000,"isPinned":false,"kind":"text","characterCount":30000,"textFileName":"b.txt","fullTextHash":"legacyhash","isTruncated":false,"originalCharacterCount":30000}\
        ],"pinboards":[]}
        """
        try Data(legacy.utf8).write(to: url)

        let store = ClipStore(files: ClipFiles(root: url.deletingLastPathComponent()))
        let image = try #require(store.items.first { $0.kind == .image })
        #expect(image.text.isEmpty)
        #expect(image.title == nil)
        #expect(image.contentHash == nil)
        #expect(store.items[1].contentHash == Clip.textIdentity("hi"))
        #expect(store.items[2].contentHash == "legacyhash")

        store.flush()
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("\"version\" : \(StoreDocument.currentVersion)"))
        #expect(!written.contains("fullTextHash"))
    }
}
