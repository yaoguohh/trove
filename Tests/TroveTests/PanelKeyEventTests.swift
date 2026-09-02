import AppKit
import SwiftUI
import Testing
@testable import Trove

/// `PanelKeyEvent.decode` bridges a raw AppKit keyDown (keyCode + modifier bits + characters) to the
/// SwiftUI key/modifiers the pure `PanelKeyboard.intent` consumes. Routing every panel key through a
/// window-level monitor (instead of the search field's onKeyPress) is what makes navigation/action keys
/// work regardless of which subview holds focus — so this decode step is the new, most regression-prone
/// surface and is pinned end-to-end here: raw keyDown → decode → intent.
struct PanelKeyEventTests {
    private func intent(
        _ keyCode: UInt16,
        mods: NSEvent.ModifierFlags = [],
        chars: String? = nil,
        queryEmpty: Bool = true,
        hasSelection: Bool = true,
        quickLook: Bool = false,
        canUndo: Bool = false
    ) -> PanelKeyIntent? {
        guard let decoded = PanelKeyEvent.decode(keyCode: keyCode, modifierRaw: mods.rawValue, characters: chars) else {
            return nil
        }
        return PanelKeyboard.intent(
            key: decoded.key,
            modifiers: decoded.modifiers,
            state: PanelInputState(
                queryIsEmpty: queryEmpty,
                hasSelection: hasSelection,
                quickLookVisible: quickLook,
                canUndoDelete: canUndo
            )
        )
    }

    @Test func escapeClosesOnEmptyQuery() {
        #expect(intent(KeyCode.escape, queryEmpty: true) == .closePanel)
    }

    @Test func escapeClearsNonEmptyQuery() {
        #expect(intent(KeyCode.escape, queryEmpty: false) == .clearQuery)
    }

    @Test func leftRightArrowsMoveSelection() {
        #expect(intent(KeyCode.leftArrow) == .moveSelection(-1))
        #expect(intent(KeyCode.rightArrow) == .moveSelection(1))
    }

    @Test func commandArrowsPageSelection() {
        #expect(intent(KeyCode.leftArrow, mods: .command) == .pageSelection(-1))
        #expect(intent(KeyCode.rightArrow, mods: .command) == .pageSelection(1))
    }

    @Test func forwardDeleteDeletesCard() {
        #expect(intent(KeyCode.forwardDelete) == .deleteSelectedCard)
    }

    @Test func commandBackspaceDeletesCard() {
        #expect(intent(KeyCode.delete, mods: .command) == .deleteSelectedCard)
    }

    @Test func plainBackspacePassesThroughToEditText() {
        #expect(intent(KeyCode.delete) == .passThrough)
    }

    @Test func returnPastes() {
        #expect(intent(KeyCode.returnKey) == .paste(plainText: false))
    }

    @Test func optionReturnPastesPlain() {
        #expect(intent(KeyCode.returnKey, mods: .option) == .paste(plainText: true))
    }

    @Test func keypadEnterPastes() {
        // The numeric-keypad Enter arrives as ETX ("\u{0003}"); intent treats it like Return.
        #expect(intent(KeyCode.keypadEnter) == .paste(plainText: false))
    }

    @Test func spaceTogglesQuickLookWithSelection() {
        #expect(intent(KeyCode.space, hasSelection: true) == .toggleQuickLook)
    }

    @Test func spaceTypesWithoutSelection() {
        #expect(intent(KeyCode.space, hasSelection: false) == .passThrough)
    }

    @Test func commandZUndoesDeleteInBrowse() {
        // ⌘Z resurrects a card only with an empty query (so it doesn't shadow the field's text-undo).
        #expect(intent(0, mods: .command, chars: "z", queryEmpty: true, canUndo: true) == .undoDelete)
    }

    @Test func commandZPassesThroughWhileSearching() {
        #expect(intent(0, mods: .command, chars: "z", queryEmpty: false, canUndo: true) == .passThrough)
    }

    @Test func printableLetterPassesThrough() {
        #expect(intent(0, chars: "a") == .passThrough)
    }

    @Test func unmappedKeyWithoutCharactersDecodesToNil() {
        // A key we don't special-case and that yields no character can't be routed → nil (pass through).
        #expect(PanelKeyEvent.decode(keyCode: 999, modifierRaw: 0, characters: nil) == nil)
    }

    @Test func modifierBitsMapToSwiftUIModifiers() {
        let decoded = PanelKeyEvent.decode(keyCode: KeyCode.rightArrow, modifierRaw: NSEvent.ModifierFlags.command.rawValue, characters: nil)
        #expect(decoded?.modifiers.contains(.command) == true)
        #expect(decoded?.modifiers.contains(.shift) == false)
    }
}
