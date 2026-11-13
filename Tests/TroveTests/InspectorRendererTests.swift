import Foundation
import Testing
@testable import Trove

struct InspectorURLTests {
    @Test func singleURLDetectedAsURL() {
        #expect(InspectorRenderer.detect("https://example.com/path", kind: .link) == .url("https://example.com/path"))
    }

    @Test func trimsSurroundingWhitespaceForURL() {
        #expect(InspectorRenderer.detect("  https://example.com  ", kind: .link) == .url("https://example.com"))
    }

    @Test func paragraphStartingWithURLIsPlain() {
        // Interior whitespace ⇒ not a single bare URL ⇒ don't render as a link card.
        #expect(InspectorRenderer.detect("https://x.com then more text", kind: .link) == .plain)
    }

    @Test func nonLinkKindIsNeverURL() {
        #expect(InspectorRenderer.detect("https://x.com", kind: .text) == .plain)
    }
}

struct InspectorExpandActionTests {
    @Test func singleURLOpensInBrowser() {
        let action = InspectorRenderer.expandAction(for: "https://example.com/path", kind: .link)
        #expect(action == .openURL(URL(string: "https://example.com/path")!))
    }

    @Test func trimmedSingleURLOpensInBrowser() {
        let action = InspectorRenderer.expandAction(for: "  https://example.com  ", kind: .link)
        #expect(action == .openURL(URL(string: "https://example.com")!))
    }

    @Test func multilineStartingWithURLUsesInspectWindow() {
        // A `.link`-kind clip that is NOT a single bare URL (interior newline) must NOT be flung at the
        // browser — it falls back to the in-app inspector.
        #expect(InspectorRenderer.expandAction(for: "https://x.com\nmore text", kind: .link) == .inspectWindow)
    }

    @Test func plainTextUsesInspectWindow() {
        #expect(InspectorRenderer.expandAction(for: "just some notes", kind: .text) == .inspectWindow)
    }

    @Test func jsonUsesInspectWindow() {
        // JSON keeps its in-app pretty-printed preview; only single URLs open in the browser.
        #expect(InspectorRenderer.expandAction(for: "{\"a\":1}", kind: .text) == .inspectWindow)
    }

    @Test func urlTextOnNonLinkKindUsesInspectWindow() {
        #expect(InspectorRenderer.expandAction(for: "https://x.com", kind: .text) == .inspectWindow)
    }
}

struct InspectorJSONTests {
    @Test func formatsValidObjectWithSortedKeys() throws {
        let pretty = InspectorRenderer.prettyJSON("{\"b\":1,\"a\":2}")
        let unwrapped = try #require(pretty)
        // Sorted keys ⇒ "a" before "b"; pretty-printed ⇒ newlines.
        let aIndex = try #require(unwrapped.range(of: "\"a\""))
        let bIndex = try #require(unwrapped.range(of: "\"b\""))
        #expect(aIndex.lowerBound < bIndex.lowerBound)
        #expect(unwrapped.contains("\n"))
    }

    @Test func detectsJSONArrayRegardlessOfKind() {
        if case .json = InspectorRenderer.detect("[1, 2, 3]", kind: .text) {
            // expected
        } else {
            Issue.record("a valid JSON array should detect as .json")
        }
    }

    @Test func rejectsInvalidJSON() {
        #expect(InspectorRenderer.prettyJSON("not json {") == nil)
    }

    @Test func rejectsNonJSONFirstChar() {
        #expect(InspectorRenderer.prettyJSON("hello world") == nil)
    }

    @Test func rejectsOverCap() {
        // A valid-ish object far over the byte cap returns nil without committing to a full parse.
        let huge = "{\"k\":\"" + String(repeating: "x", count: 300 * 1024) + "\"}"
        #expect(InspectorRenderer.prettyJSON(huge, maxBytes: 256 * 1024) == nil)
    }
}
