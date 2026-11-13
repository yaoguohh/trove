import Foundation
import AppKit
import Carbon
import Combine
import Testing
@testable import Trove

struct ContentDisplayCapTests {
    @Test func previewTakesPrefixBeforeNewlineReplace() {
        // 2× the cap in characters, every other one a newline — an uncapped excerpt flattened the whole
        // multi-MB string; now it must bound the work to `excerptCap`.
        let huge = String(repeating: "a\n", count: Clip.excerptCap)
        let item = Clip(text: huge, sourceApp: "X")
        #expect(item.excerpt.count <= Clip.excerptCap)
    }

    @Test func shortPreviewIsUnchanged() {
        let item = Clip(text: "line one\nline two", sourceApp: "X")
        #expect(item.excerpt == "line one line two")
    }
}

struct ClipImageTests {
    @Test func imageCharacterCountStaysZero() {
        // Guards the init special-case (characterCount == 0 for images) through the new field set.
        let item = Clip(text: "", sourceApp: "X", kind: .image)
        #expect(item.characterCount == 0)
        #expect(item.originalCharacterCount == 0)
        #expect(item.isTruncated == false)
    }
}

struct ClipKindDetectionTests {
    @Test func detectsLinks() {
        #expect(Clip.detectKind(for: "https://example.com/path") == .link)
        #expect(Clip.detectKind(for: "  http://example.com  ") == .link)
    }

    @Test func detectsEmails() {
        #expect(Clip.detectKind(for: "person@example.com") == .email)
        #expect(Clip.detectKind(for: "first.last@sub.example.co") == .email)
    }

    @Test func detectsCodeByBracesOrKeywords() {
        #expect(Clip.detectKind(for: "func greet() { print(\"hi\") }") == .code)
        #expect(Clip.detectKind(for: "import Foundation") == .code)
        #expect(Clip.detectKind(for: "class Foo {}") == .code)
    }

    @Test func fallsBackToPlainText() {
        #expect(Clip.detectKind(for: "just some words") == .text)
        #expect(Clip.detectKind(for: "not-an-email@") == .text)
    }
}

struct ClipKindTests {
    @Test func onlyASingleBareURLIsALink() {
        #expect(Clip.detectKind(for: "  https://example.com/a  ") == .link)
        #expect(Clip.detectKind(for: "https://example.com then some words") == .text)
        #expect(Clip.detectKind(for: "https://a.com\nhttps://b.com") == .text)
    }

    @Test func unknownOrStaleKindsAreRedetectedOnDecode() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","text":"plain words","sourceApp":"X","createdAt":0,"isPinned":false,"kind":"file","characterCount":0,"isTruncated":false,"originalCharacterCount":0},\
        {"id":"\(UUID().uuidString)","text":"https://x.com and more","sourceApp":"X","createdAt":0,"isPinned":false,"kind":"link","characterCount":0,"isTruncated":false,"originalCharacterCount":0}]
        """
        let items = try JSONDecoder().decode([Clip].self, from: Data(json.utf8))
        #expect(items.map(\.kind) == [.text, .text])
    }
}

struct ClipNameTests {
    @Test func nameIsTheCustomTitleElseTheKind() {
        var item = Clip(text: "some words", sourceApp: "X")
        #expect(item.name == ClipKind.text.title)
        #expect(item.displayTitle == "some words")
        item.title = "Renamed"
        #expect(item.name == "Renamed")
        #expect(item.displayTitle == "Renamed")
    }
}
