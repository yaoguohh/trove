import Testing
@testable import Trove
import CoreFoundation

struct PasteExecutorTests {
    // The usual case: the panel never took activation, so the target is still frontmost. Text goes by
    // ⌘V — Chromium/Electron fields report success for an Accessibility write without writing anything.
    @Test func frontmostTargetGetsTextByKeystroke() {
        #expect(!PasteExecutor.triesAccessibilityFirst(hasText: true, targetIsFrontmost: true))
    }

    // Trove is active (the inspector is open): ⌘V would need the target activated, which raises its
    // windows, so Accessibility insertion is tried first.
    @Test func backgroundTargetGetsTextByAccessibilityFirst() {
        #expect(PasteExecutor.triesAccessibilityFirst(hasText: true, targetIsFrontmost: false))
    }

    @Test func imagesAlwaysGoByKeystroke() {
        #expect(!PasteExecutor.triesAccessibilityFirst(hasText: false, targetIsFrontmost: false))
        #expect(!PasteExecutor.triesAccessibilityFirst(hasText: false, targetIsFrontmost: true))
    }

    @Test func replacesCollapsedRangeAtCursor() {
        let result = PasteExecutor.replacingText(
            in: "Hello world",
            selectedRange: CFRange(location: 5, length: 0),
            with: ", Trove"
        )

        #expect(result == "Hello, Trove world")
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
