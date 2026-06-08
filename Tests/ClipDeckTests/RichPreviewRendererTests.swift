import Foundation
import Testing
@testable import ClipDeck

struct RichPreviewURLTests {
    @Test func singleURLDetectedAsURL() {
        #expect(RichPreviewRenderer.detect("https://example.com/path", kind: .link) == .url("https://example.com/path"))
    }

    @Test func trimsSurroundingWhitespaceForURL() {
        #expect(RichPreviewRenderer.detect("  https://example.com  ", kind: .link) == .url("https://example.com"))
    }

    @Test func paragraphStartingWithURLIsPlain() {
        // Interior whitespace ⇒ not a single bare URL ⇒ don't render as a link card.
        #expect(RichPreviewRenderer.detect("https://x.com then more text", kind: .link) == .plain)
    }

    @Test func nonLinkKindIsNeverURL() {
        #expect(RichPreviewRenderer.detect("https://x.com", kind: .text) == .plain)
    }
}

struct RichPreviewExpandActionTests {
    @Test func singleURLOpensInBrowser() {
        let action = RichPreviewRenderer.expandAction(for: "https://example.com/path", kind: .link)
        #expect(action == .openURL(URL(string: "https://example.com/path")!))
    }

    @Test func trimmedSingleURLOpensInBrowser() {
        let action = RichPreviewRenderer.expandAction(for: "  https://example.com  ", kind: .link)
        #expect(action == .openURL(URL(string: "https://example.com")!))
    }

    @Test func multilineStartingWithURLUsesInspectWindow() {
        // A `.link`-kind clip that is NOT a single bare URL (interior newline) must NOT be flung at the
        // browser — it falls back to the in-app inspect window.
        #expect(RichPreviewRenderer.expandAction(for: "https://x.com\nmore text", kind: .link) == .inspectWindow)
    }

    @Test func plainTextUsesInspectWindow() {
        #expect(RichPreviewRenderer.expandAction(for: "just some notes", kind: .text) == .inspectWindow)
    }

    @Test func jsonUsesInspectWindow() {
        // JSON keeps its in-app pretty-printed preview; only single URLs open in the browser.
        #expect(RichPreviewRenderer.expandAction(for: "{\"a\":1}", kind: .text) == .inspectWindow)
    }

    @Test func urlTextOnNonLinkKindUsesInspectWindow() {
        #expect(RichPreviewRenderer.expandAction(for: "https://x.com", kind: .text) == .inspectWindow)
    }
}

struct RichPreviewJSONTests {
    @Test func formatsValidObjectWithSortedKeys() throws {
        let pretty = RichPreviewRenderer.prettyJSON("{\"b\":1,\"a\":2}")
        let unwrapped = try #require(pretty)
        // Sorted keys ⇒ "a" before "b"; pretty-printed ⇒ newlines.
        let aIndex = try #require(unwrapped.range(of: "\"a\""))
        let bIndex = try #require(unwrapped.range(of: "\"b\""))
        #expect(aIndex.lowerBound < bIndex.lowerBound)
        #expect(unwrapped.contains("\n"))
    }

    @Test func detectsJSONArrayRegardlessOfKind() {
        if case .json = RichPreviewRenderer.detect("[1, 2, 3]", kind: .text) {
            // expected
        } else {
            Issue.record("a valid JSON array should detect as .json")
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(RichPreviewRenderer.prettyJSON("not json {") == nil)
    }

    @Test func rejectsNonJSONFirstChar() {
        #expect(RichPreviewRenderer.prettyJSON("hello world") == nil)
    }

    @Test func rejectsOverCap() {
        // A valid-ish object far over the byte cap returns nil without committing to a full parse.
        let huge = "{\"k\":\"" + String(repeating: "x", count: 300 * 1024) + "\"}"
        #expect(RichPreviewRenderer.prettyJSON(huge, maxBytes: 256 * 1024) == nil)
    }
}
