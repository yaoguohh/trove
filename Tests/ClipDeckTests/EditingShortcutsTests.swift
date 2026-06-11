import Testing
@testable import ClipDeck

struct EditingShortcutsTests {
    @Test func mapsStandardEditingKeys() {
        #expect(EditingShortcuts.actionName(forKey: "c") == "copy:")
        #expect(EditingShortcuts.actionName(forKey: "x") == "cut:")
        #expect(EditingShortcuts.actionName(forKey: "v") == "paste:")
        #expect(EditingShortcuts.actionName(forKey: "a") == "selectAll:")
    }

    @Test func upperCaseKeysStillMap() {
        // charactersIgnoringModifiers can arrive upper-case under caps lock.
        #expect(EditingShortcuts.actionName(forKey: "C") == "copy:")
    }

    @Test func leavesOtherKeysToTheKeyboardModel() {
        // ⌘Z (card undo) and any other key must NOT be claimed as an editing shortcut, so the panel's
        // own keyboard model keeps them.
        #expect(EditingShortcuts.actionName(forKey: "z") == nil)
        #expect(EditingShortcuts.actionName(forKey: "s") == nil)
    }
}
