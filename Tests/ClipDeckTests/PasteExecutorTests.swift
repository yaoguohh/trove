import CoreFoundation
import Testing
@testable import ClipDeck

struct PasteExecutorTests {
    @Test func replacesCollapsedRangeAtCursor() {
        let result = PasteExecutor.replacingText(
            in: "Hello world",
            selectedRange: CFRange(location: 5, length: 0),
            with: ", ClipDeck"
        )

        #expect(result == "Hello, ClipDeck world")
    }

    @Test func replacesSelectedRange() {
        let result = PasteExecutor.replacingText(
            in: "Hello old world",
            selectedRange: CFRange(location: 6, length: 3),
            with: "new"
        )

        #expect(result == "Hello new world")
    }

    @Test func respectsUTF16Offsets() {
        let result = PasteExecutor.replacingText(
            in: "Hi 👋 world",
            selectedRange: CFRange(location: 6, length: 0),
            with: "there "
        )

        #expect(result == "Hi 👋 there world")
    }

    @Test func rejectsOutOfBoundsRange() {
        let result = PasteExecutor.replacingText(
            in: "Hello",
            selectedRange: CFRange(location: 9, length: 1),
            with: "!"
        )

        #expect(result == nil)
    }
}
