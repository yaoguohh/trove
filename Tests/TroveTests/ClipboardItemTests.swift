import AppKit
import Carbon
import Testing
@testable import Trove

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

struct ClipboardItemKindTests {
    @Test func onlyASingleBareURLIsALink() {
        #expect(ClipboardItem.detectKind(for: "  https://example.com/a  ") == .link)
        #expect(ClipboardItem.detectKind(for: "https://example.com then some words") == .text)
        #expect(ClipboardItem.detectKind(for: "https://a.com\nhttps://b.com") == .text)
    }

    @Test func unknownOrStaleKindsAreRedetectedOnDecode() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","text":"plain words","sourceApp":"X","createdAt":0,"isPinned":false,"kind":"file","characterCount":0,"isTruncated":false,"originalCharacterCount":0},\
        {"id":"\(UUID().uuidString)","text":"https://x.com and more","sourceApp":"X","createdAt":0,"isPinned":false,"kind":"link","characterCount":0,"isTruncated":false,"originalCharacterCount":0}]
        """
        let items = try JSONDecoder().decode([ClipboardItem].self, from: Data(json.utf8))
        #expect(items.map(\.kind) == [.text, .text])
    }
}

@MainActor
struct ShortcutSymbolTests {
    @Test func modifiersRoundTripThroughCarbonMasks() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        let carbon = ModifierKey.carbon(from: flags)
        #expect(ModifierKey.symbols(carbon: carbon) == ["⇧", "⌘"])
        #expect(ModifierKey.symbols(flags: flags) == ["⇧", "⌘"])
    }

    @Test func keysThatPrintNothingHaveFixedSymbols() {
        #expect(KeyCodeNames.symbol(for: UInt32(kVK_Space)) == "␣")
        #expect(KeyCodeNames.symbol(for: UInt32(kVK_F5)) == "F5")
    }

    @Test func characterKeysShowWhatTheLayoutTypes() {
        let symbol = KeyCodeNames.symbol(for: UInt32(kVK_ANSI_V))
        #expect(symbol.count == 1)
        #expect(symbol == symbol.uppercased())
    }
}

struct ImageFitTests {
    @Test func neverUpscalesAndKeepsTheAspect() {
        let fitted = ImageFit.size(of: CGSize(width: 400, height: 200), within: CGSize(width: 1000, height: 1000), atLeast: .zero)
        #expect(fitted == CGSize(width: 400, height: 200))
        let shrunk = ImageFit.size(of: CGSize(width: 2000, height: 1000), within: CGSize(width: 1000, height: 1000), atLeast: .zero)
        #expect(shrunk == CGSize(width: 1000, height: 500))
    }

    @Test func floorStopsSliversButBoundsWin() {
        let sliver = ImageFit.size(of: CGSize(width: 2000, height: 10), within: CGSize(width: 1000, height: 1000), atLeast: CGSize(width: 200, height: 130))
        #expect(sliver == CGSize(width: 1000, height: 130))
        let tight = ImageFit.size(of: CGSize(width: 50, height: 50), within: CGSize(width: 150, height: 100), atLeast: CGSize(width: 200, height: 130))
        #expect(tight == CGSize(width: 150, height: 100))
    }
}

struct ClipboardItemNameTests {
    @Test func nameIsTheCustomTitleElseTheKind() {
        var item = ClipboardItem(text: "some words", sourceApp: "X")
        #expect(item.name == ClipboardKind.text.title)
        #expect(item.displayTitle == "some words")
        item.title = "Renamed"
        #expect(item.name == "Renamed")
        #expect(item.displayTitle == "Renamed")
    }
}
