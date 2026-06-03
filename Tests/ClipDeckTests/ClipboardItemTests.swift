import Testing
@testable import ClipDeck

struct ClipboardKindDetectionTests {
    @Test func detectsLinks() {
        #expect(ClipboardItem.detectKind(for: "https://example.com/path") == .link)
        #expect(ClipboardItem.detectKind(for: "  http://example.com  ") == .link)
    }

    @Test func detectsEmails() {
        #expect(ClipboardItem.detectKind(for: "person@example.com") == .email)
        #expect(ClipboardItem.detectKind(for: "first.last@sub.example.co") == .email)
    }

    @Test func detectsCodeByBracesOrKeywords() {
        #expect(ClipboardItem.detectKind(for: "func greet() { print(\"hi\") }") == .code)
        #expect(ClipboardItem.detectKind(for: "import Foundation") == .code)
        #expect(ClipboardItem.detectKind(for: "class Foo {}") == .code)
    }

    @Test func fallsBackToPlainText() {
        #expect(ClipboardItem.detectKind(for: "just some words") == .text)
        #expect(ClipboardItem.detectKind(for: "not-an-email@") == .text)
    }
}
