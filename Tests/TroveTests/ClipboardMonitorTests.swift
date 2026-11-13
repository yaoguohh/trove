import AppKit
import Testing
@testable import Trove

@MainActor
struct ClipboardMonitorTests {
    private func makeStore() -> ClipboardStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TroveTests-\(UUID().uuidString)", isDirectory: true)
        return ClipboardStore(files: ClipFiles(root: root))
    }

    private func write(_ text: String, to pasteboard: NSPasteboard, extraTypes: [NSPasteboard.PasteboardType] = []) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string] + extraTypes, owner: nil)
        pasteboard.setString(text, forType: .string)
        for type in extraTypes {
            pasteboard.setData(Data(), forType: type)
        }
    }

    @Test func newCopyIsAddedOnce() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = makeStore()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

        write("hello", to: pasteboard)
        monitor.poll()
        monitor.poll()   // no change since the last tick → nothing new

        #expect(store.items.map(\.text) == ["hello"])
    }

    @Test func ownWriteBackIsNotIngested() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = makeStore()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)
        let clipPasteboard = ClipPasteboard(store: store, monitor: monitor, pasteboard: pasteboard)
        store.add(text: "older", sourceApp: "X")
        store.add(text: "newer", sourceApp: "X")

        clipPasteboard.copy(store.items.first { $0.text == "older" }!)
        monitor.poll()

        // Re-ingesting would have moved "older" to the top.
        #expect(store.items.map(\.text) == ["newer", "older"])
        #expect(pasteboard.string(forType: .string) == "older")
    }

    @Test func concealedCopyIsSkipped() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let store = makeStore()
        let monitor = ClipboardMonitor(store: store, pasteboard: pasteboard)

        write("secret", to: pasteboard, extraTypes: [NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")])
        monitor.poll()

        #expect(store.items.isEmpty)
    }
}
