import SwiftUI
import Testing
@testable import ClipDeck

/// Pins the panel keyboard model (PanelKeyboard.intent) — the most regression-prone surface — as a
/// pure decision table. The search field is always focused; these are the keys it intercepts.
private func decide(
    _ key: KeyEquivalent,
    _ modifiers: EventModifiers = [],
    queryEmpty: Bool = true,
    hasSelection: Bool = true,
    quickLook: Bool = false,
    canUndo: Bool = false
) -> PanelKeyIntent {
    PanelKeyboard.intent(
        key: key,
        modifiers: modifiers,
        state: PanelInputState(
            queryIsEmpty: queryEmpty,
            hasSelection: hasSelection,
            quickLookVisible: quickLook,
            canUndoDelete: canUndo
        )
    )
}

struct PanelKeyboardEscapeTests {
    @Test func dismissesPeekFirst() {
        #expect(decide(.escape, queryEmpty: false, quickLook: true) == .dismissQuickLook)
    }
    @Test func closesWhenQueryEmpty() {
        #expect(decide(.escape) == .closePanel)
    }
    @Test func clearsNonEmptyQuery() {
        #expect(decide(.escape, queryEmpty: false) == .clearQuery)
    }
}

struct PanelKeyboardReturnTests {
    @Test func returnPastes() {
        #expect(decide(.return) == .paste(plainText: false))
    }
    @Test func keypadEnterAlsoPastes() {
        // The numeric-keypad Enter key arrives as the ETX character, not .return.
        #expect(decide(KeyEquivalent("\u{0003}")) == .paste(plainText: false))
    }
    @Test func optionReturnPastesPlain() {
        #expect(decide(.return, [.option]) == .paste(plainText: true))
    }
    @Test func returnWithUnhandledModifierPassesThrough() {
        #expect(decide(.return, [.command]) == .passThrough)
    }
}

struct PanelKeyboardNavigationTests {
    @Test func arrowsMoveSelection() {
        #expect(decide(.leftArrow) == .moveSelection(-1))
        #expect(decide(.rightArrow) == .moveSelection(1))
    }
    @Test func verticalArrowsPassThrough() {
        // Horizontal strip — ↑/↓ aren't intercepted; they fall through to the search field.
        #expect(decide(.upArrow) == .passThrough)
        #expect(decide(.downArrow) == .passThrough)
    }
    @Test func commandArrowsPage() {
        #expect(decide(.leftArrow, [.command]) == .pageSelection(-1))
        #expect(decide(.rightArrow, [.command]) == .pageSelection(1))
    }
    @Test func shiftDoesNotBlockArrowNavigation() {
        #expect(decide(.leftArrow, [.shift]) == .moveSelection(-1))
    }
}

struct PanelKeyboardDeleteTests {
    @Test func forwardDeleteDeletesCard() {
        #expect(decide(.deleteForward) == .deleteSelectedCard)
    }
    @Test func commandBackspaceDeletesCard() {
        #expect(decide(.delete, [.command]) == .deleteSelectedCard)
    }
    @Test func plainBackspacePassesThroughToEditTheQuery() {
        #expect(decide(.delete) == .passThrough)
    }
}

struct PanelKeyboardSpaceTests {
    @Test func spacePeeksWheneverSomethingIsSelected() {
        // Peek works regardless of the search query (IME composition is filtered out upstream).
        #expect(decide(.space, queryEmpty: true, hasSelection: true) == .toggleQuickLook)
        #expect(decide(.space, queryEmpty: false, hasSelection: true) == .toggleQuickLook)
    }
    @Test func spaceTypesWhenNothingSelected() {
        #expect(decide(.space, hasSelection: false) == .passThrough)
    }
}

struct PanelKeyboardUndoTests {
    @Test func commandZUndoesWhenSomethingToUndo() {
        #expect(decide("z", [.command], canUndo: true) == .undoDelete)
        #expect(decide("Z", [.command], canUndo: true) == .undoDelete) // caps-lock variant
    }
    @Test func commandZWhileTypingSearchDoesTextUndoNotCardUndo() {
        // Non-empty query ⇒ the user is editing search text; ⌘Z must reach the field's native text
        // undo, never resurrect a card — even when a deleted card is available.
        #expect(decide("z", [.command], queryEmpty: false, canUndo: true) == .passThrough)
    }
    @Test func commandZPassesThroughWhenNothingToUndo() {
        // No card-deletes to undo → ⌘Z falls through to the search field's own text undo.
        #expect(decide("z", [.command], canUndo: false) == .passThrough)
    }
    @Test func shiftCommandZIsNotUndo() {
        // ⇧⌘Z (redo) is intentionally unsupported — it must never be read as undo.
        #expect(decide("z", [.command, .shift], canUndo: true) == .passThrough)
    }
    @Test func plainZTypesIntoTheQuery() {
        #expect(decide("z", canUndo: true) == .passThrough)
    }
}

struct PanelKeyboardPrintableTests {
    @Test func lettersFallThroughToTheSearchField() {
        #expect(decide("a") == .passThrough)
        #expect(decide("N", [.shift]) == .passThrough)
    }
}
