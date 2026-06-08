import Foundation
import Testing
@testable import ClipDeck

@MainActor
private func makeTempStore() -> (ClipboardStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipDeckTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("history.json")
    return (ClipboardStore(storeURL: url), url)
}

@MainActor
struct ClipboardStoreDedupTests {
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
struct ClipboardStoreMutationTests {
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
struct ClipboardStorePinboardReorderTests {
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
struct ClipboardStoreLoadTests {
    @Test func corruptFileIsBackedUpNotSilentlyWiped() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.json")
        let corruptBytes = Data("this is not valid json".utf8)
        try corruptBytes.write(to: url)

        _ = ClipboardStore(storeURL: url)

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

struct ContentDisplayCapTests {
    @Test func previewTakesPrefixBeforeNewlineReplace() {
        // 2× the cap in characters, every other one a newline — the old `preview` flattened the whole
        // multi-MB string; now it must bound the work to `displayPreviewCap`.
        let huge = String(repeating: "a\n", count: ClipboardItem.displayPreviewCap)
        let item = ClipboardItem(text: huge, sourceApp: "X")
        #expect(item.preview.count <= ClipboardItem.displayPreviewCap)
    }

    @Test func shortPreviewIsUnchanged() {
        let item = ClipboardItem(text: "line one\nline two", sourceApp: "X")
        #expect(item.preview == "line one line two")
    }
}

@MainActor
struct ContentSearchCapTests {
    @Test func matchesScansOnlyCappedPrefix() {
        let (store, _) = makeTempStore()
        // "FINDME" sits at the very start; "TAILONLY" sits well past the 20k search-scan cap.
        let filler = String(repeating: "x", count: 20_000 + 200)
        store.add(text: "FINDME" + filler + "TAILONLY", sourceApp: "X")

        #expect(!store.matches(query: "FINDME").isEmpty)  // in the scanned prefix → found
        #expect(store.matches(query: "TAILONLY").isEmpty) // past the cap → not surfaced (documented)
    }
}

// Note: an injected `storeURL` makes the store NOT manage sidecar files, so a big clip keeps its full
// text INLINE (with a hash). `fullText` therefore equals `text` here — the dedup/flag/migration logic
// is still fully exercised; only the on-disk `.txt` spill is mode-gated off in tests.
@MainActor
struct ClipboardStoreSidecarTests {
    @Test func subThresholdStoresVerbatimNoSidecar() {
        let (store, _) = makeTempStore()
        store.add(text: "small clip", sourceApp: "X")
        let item = store.items[0]
        #expect(item.textFileName == nil)
        #expect(item.fullTextHash == nil)
        #expect(item.fullText == "small clip")
        #expect(item.isTruncated == false)
        #expect(item.characterCount == 10)
    }

    @Test func aboveCeilingTruncatesAndFlags() {
        let (store, _) = makeTempStore()
        let original = ClipboardItem.ultimateSidecarCeiling + 100
        store.add(text: String(repeating: "a", count: original), sourceApp: "X")
        let item = store.items[0]
        #expect(item.text.count == ClipboardItem.ultimateSidecarCeiling)
        #expect(item.isTruncated == true)
        #expect(item.originalCharacterCount == original)
        #expect(item.characterCount == original) // footer shows the TRUE source length
    }

    @Test func dedupBigClipByContent() {
        let (store, _) = makeTempStore()
        let big = String(repeating: "z", count: ClipboardItem.sidecarThreshold + 500)
        store.add(text: big, sourceApp: "X")
        store.add(text: big, sourceApp: "Y")
        #expect(store.items.count == 1)
        #expect(store.items[0].fullTextHash != nil)
    }

    @Test func bigClipDedupsAcrossSurroundingWhitespace() {
        // The P1 fix: dedup key is the hash of the NORMALIZED form, so a re-copy that differs only by
        // surrounding whitespace (a toggled trailing newline) dedups instead of writing a 2nd entry.
        let (store, _) = makeTempStore()
        let big = String(repeating: "q", count: ClipboardItem.sidecarThreshold + 500)
        store.add(text: big, sourceApp: "X")
        store.add(text: "  " + big + "\n", sourceApp: "Y")
        #expect(store.items.count == 1)
    }

    @Test func dedupKeepsDistinctBigClips() {
        let (store, _) = makeTempStore()
        let base = String(repeating: "z", count: ClipboardItem.sidecarThreshold + 500)
        store.add(text: base + "ONE", sourceApp: "X")
        store.add(text: base + "TWO", sourceApp: "X")
        #expect(store.items.count == 2)
    }

    @Test func dedupBoundaryCrossingThreshold() {
        let (store, _) = makeTempStore()
        store.add(text: "short", sourceApp: "X")
        store.add(text: String(repeating: "z", count: ClipboardItem.sidecarThreshold + 500), sourceApp: "X")
        // A nil-hash (small) item and a hashed (big) item never false-match.
        #expect(store.items.count == 2)
    }

    @Test func smallClipWhitespaceDedupStillPasses() {
        let (store, _) = makeTempStore()
        store.add(text: "foo", sourceApp: "X")
        store.add(text: "  foo  ", sourceApp: "X")
        #expect(store.items.count == 1)
    }
}

struct ClipboardItemImageTests {
    @Test func imageCharacterCountStaysZero() {
        // Guards the init special-case (characterCount == 0 for images) through the new field set.
        let item = ClipboardItem(text: "Image", sourceApp: "X", kind: .image)
        #expect(item.characterCount == 0)
        #expect(item.originalCharacterCount == 0)
        #expect(item.isTruncated == false)
    }
}

@MainActor
struct ClipboardItemMigrationTests {
    @Test func legacyJSONDecodesWithoutNewKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipDeckTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.json")
        // A pre-sidecar document: items carry NONE of textFileName/fullTextHash/isTruncated/
        // originalCharacterCount. createdAt is the default deferred-to-date Double form.
        let legacy = """
        {"items":[{"id":"\(UUID().uuidString)","text":"hello world","sourceApp":"Safari","createdAt":700000000,"isPinned":false,"kind":"text","characterCount":11}],"pinboards":[]}
        """
        try Data(legacy.utf8).write(to: url)

        let store = ClipboardStore(storeURL: url)
        #expect(store.items.count == 1)
        let item = store.items[0]
        #expect(item.text == "hello world")
        #expect(item.hasSidecarText == false)
        #expect(item.fullText == "hello world")
        #expect(item.isTruncated == false)
        #expect(item.originalCharacterCount == item.characterCount)
    }
}

@MainActor
struct ClipboardFidelityTests {
    @Test func fullTextEqualsInlineForSubThreshold() {
        let (store, _) = makeTempStore()
        store.add(text: "verbatim paste fidelity", sourceApp: "X")
        let item = store.items[0]
        #expect(item.fullText == item.text)
    }

    @Test func missingSidecarDegradesToInlinePrefix() {
        // A clip that claims a sidecar whose file is gone must NOT crash; fullText falls back to text.
        var item = ClipboardItem(text: "inline prefix", sourceApp: "X")
        item.textFileName = "missing-\(UUID().uuidString).txt"
        #expect(item.fullText == "inline prefix")
    }

    // The store's managed-mode write can't be driven hermetically (its sidecar dir is the global
    // AppPaths one, and forcing managed mode would run reconcile against a real install). Instead this
    // exercises the SAME round-trip at the item level: a real sidecar on disk (unique name + cleanup),
    // read back through fullText, with the inline prefix kept distinct — the fidelity invariant that
    // every >sidecarThreshold clip depends on.
    @Test func spilledClipRoundTripsFullTextFromSidecar() throws {
        let dir = ClipboardItem.textDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "test-\(UUID().uuidString).txt"
        let url = dir.appendingPathComponent(name)
        let full = String(repeating: "Z", count: ClipboardItem.inlineTextCap + 5_000)
        try Data(full.utf8).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        var item = ClipboardItem(text: String(full.prefix(ClipboardItem.inlineTextCap)), sourceApp: "X")
        item.textFileName = name

        #expect(item.fullText == full)                            // reads the sidecar → full fidelity
        #expect(item.text.count == ClipboardItem.inlineTextCap)   // inline keeps only the prefix
        #expect(item.text != item.fullText)                       // the spilled-clip invariant

        // The inspect-window bounded reader also pulls from the sidecar (FileHandle branch).
        let bounded = PreviewWindowController.boundedBody(for: item)
        #expect(bounded.text == full)        // 25k < 256KB budget → shown whole
        #expect(bounded.isClipped == false)
    }
}

@MainActor
struct PreviewWindowBoundedBodyTests {
    @Test func inlineShortTextIsNotClipped() {
        let item = ClipboardItem(text: "short inline body", sourceApp: "X")
        let result = PreviewWindowController.boundedBody(for: item)
        #expect(result.text == "short inline body")
        #expect(result.isClipped == false)
    }

    @Test func missingSidecarDegradesToInlinePrefix() {
        // textFileURL is non-nil but the file is gone → FileHandle open fails → inline-prefix branch.
        var item = ClipboardItem(text: "inline only", sourceApp: "X")
        item.textFileName = "missing-\(UUID().uuidString).txt"
        let result = PreviewWindowController.boundedBody(for: item)
        #expect(result.text == "inline only")
        #expect(result.isClipped == false)
    }

    @Test func oversizeSidecarIsClippedAtScalarBoundary() throws {
        let dir = ClipboardItem.textDirectoryURL
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "test-\(UUID().uuidString).txt"
        let url = dir.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: url) }
        // Multi-byte scalars (3 bytes each) so the 256KB byte cut lands mid-scalar — exercises both
        // the clipped path and the trailing U+FFFD trim.
        let big = String(repeating: "界", count: 120_000) // 360,000 UTF-8 bytes > 262,144 cap
        try Data(big.utf8).write(to: url, options: .atomic)

        var item = ClipboardItem(text: String(big.prefix(ClipboardItem.inlineTextCap)), sourceApp: "X")
        item.textFileName = name

        let result = PreviewWindowController.boundedBody(for: item)
        #expect(result.isClipped == true)
        #expect(result.text.utf8.count <= PreviewWindowController.previewWindowCap)
        #expect(!result.text.hasSuffix("\u{FFFD}")) // partial trailing scalar was trimmed
    }
}
