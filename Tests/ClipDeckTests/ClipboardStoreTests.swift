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
