import Foundation
import Combine
import Testing
@testable import Trove

@MainActor
struct InspectorBoundedBodyTests {
    private let files = ClipFiles(root: makeTempDirectory())

    @Test func inlineShortTextIsNotClipped() {
        let item = Clip(text: "short inline body", sourceApp: "X")
        let result = InspectorController.boundedBody(for: item, in: files)
        #expect(result.text == "short inline body")
        #expect(result.isClipped == false)
    }

    @Test func missingSidecarDegradesToInlinePrefix() {
        // The sidecar path is set but the file is gone → FileHandle open fails → inline-prefix branch.
        var item = Clip(text: "inline only", sourceApp: "X")
        item.textFileName = "missing-\(UUID().uuidString).txt"
        let result = InspectorController.boundedBody(for: item, in: files)
        #expect(result.text == "inline only")
        #expect(result.isClipped == false)
    }

    @Test func oversizeSidecarIsClippedAtScalarBoundary() throws {
        // Multi-byte scalars (3 bytes each) so the 256KB byte cut lands mid-scalar — exercises both
        // the clipped path and the trailing U+FFFD trim.
        let big = String(repeating: "界", count: 120_000) // 360,000 UTF-8 bytes > 262,144 cap
        var item = Clip(text: String(big.prefix(Clip.inlineTextCap)), sourceApp: "X")
        item.textFileName = try files.writeText(big, for: item.id)

        let result = InspectorController.boundedBody(for: item, in: files)
        #expect(result.isClipped == true)
        #expect(result.text.utf8.count <= InspectorController.textBudget)
        #expect(!result.text.hasSuffix("\u{FFFD}")) // partial trailing scalar was trimmed
    }
}
