import Foundation
import Combine
import Testing
@testable import Trove

@MainActor
struct ClipFilesFidelityTests {
    @Test func fullTextEqualsInlineForSubThreshold() {
        let (store, _) = makeTempStore()
        store.add(text: "verbatim paste fidelity", sourceApp: "X")
        let item = store.items[0]
        #expect(store.files.fullText(of: item) == item.text)
    }

    @Test func missingSidecarDegradesToInlinePrefix() {
        // A clip that claims a sidecar whose file is gone must NOT crash; fullText falls back to text.
        let (store, _) = makeTempStore()
        var item = Clip(text: "inline prefix", sourceApp: "X")
        item.textFileName = "missing-\(UUID().uuidString).txt"
        #expect(store.files.fullText(of: item) == "inline prefix")
    }

    @Test func spilledClipRoundTripsFullTextFromSidecar() throws {
        let (store, _) = makeTempStore()
        let full = String(repeating: "Z", count: Clip.inlineTextCap + 5_000)
        store.add(text: full, sourceApp: "X")
        let item = store.items[0]

        let sidecar = try #require(store.files.textURL(for: item))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(store.files.fullText(of: item) == full)            // reads the sidecar → full fidelity
        #expect(item.text.count == Clip.inlineTextCap)    // inline keeps only the prefix

        // The inspect-window bounded reader also pulls from the sidecar (FileHandle branch).
        let bounded = InspectorController.boundedBody(for: item, in: store.files)
        #expect(bounded.text == full)        // 25k < 256KB budget → shown whole
        #expect(bounded.isClipped == false)
    }
}
