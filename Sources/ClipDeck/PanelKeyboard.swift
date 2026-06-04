import SwiftUI

/// The single focus authority for the panel: exactly one of these can be focused at a time, so
/// binding every field to ONE `@FocusState<PanelFocus?>` makes focus atomic and mutually exclusive
/// (the canonical SwiftUI fix for focus cross-talk between the search field and a rename editor).
enum PanelFocus: Hashable {
    case search
    case rename(ClipboardItem.ID)
}

/// What a keystroke should DO in the panel, decided purely from the key + modifiers + a snapshot of
/// panel state. The search field is ALWAYS the focused field; navigation/action keys are intercepted
/// (`.handled`) by its `onKeyPress` and routed here, while printable keys and plain ⌫ fall through
/// (`.passThrough`/`.ignored`) and edit the search text natively. Keeping the decision pure means the
/// keyboard model — the most regression-prone surface — is exhaustively unit-testable.
enum PanelKeyIntent: Equatable {
    /// Don't intercept — let the focused search field handle it (printable keys, ⌫, ↑/↓, a space mid-search).
    case passThrough

    case moveSelection(Int)    // ←/→ : move the card selection
    case pageSelection(Int)    // ⌘←/⌘→ : direction (-1/+1); executor scales by the page size
    case paste(plainText: Bool)
    case deleteSelectedCard    // ⌦ or ⌘⌫
    case toggleQuickLook       // Space over a selected card with an empty search
    case dismissQuickLook      // Esc while the peek bubble is open
    case clearQuery            // Esc with a non-empty search
    case closePanel            // Esc with an empty search
}

/// The minimal panel state the keyboard decision depends on — a value type so tests construct it
/// directly without an NSEvent or a live panel.
struct PanelInputState: Equatable {
    var queryIsEmpty: Bool
    var hasSelection: Bool
    var quickLookVisible: Bool
}

enum PanelKeyboard {
    /// Pure mapping from a key press (SwiftUI `KeyEquivalent` + `EventModifiers`) to an intent.
    static func intent(key: KeyEquivalent, modifiers: EventModifiers, state: PanelInputState) -> PanelKeyIntent {
        let mods = modifiers.intersection([.command, .control, .option, .shift])

        // Esc: dismiss the peek first, then clear a non-empty search, then close.
        if key == .escape, mods.isEmpty {
            if state.quickLookVisible { return .dismissQuickLook }
            return state.queryIsEmpty ? .closePanel : .clearQuery
        }

        // Return / numeric-keypad Enter (the keypad/Enter key arrives as the ETX character) pastes
        // the selection. ⌥Return pastes plain.
        if key == .return || key == KeyEquivalent("\u{0003}") {
            if mods == .option { return .paste(plainText: true) }
            return mods.isEmpty ? .paste(plainText: false) : .passThrough
        }

        // ⌘←/⌘→ page the selection; ⌘⌫ deletes the card.
        if mods == .command {
            switch key {
            case .leftArrow: return .pageSelection(-1)
            case .rightArrow: return .pageSelection(1)
            case .delete: return .deleteSelectedCard
            default: return .passThrough
            }
        }

        // Other modifier combos (⌃/⌥/⌘ mixes) — let the field/system have them. Shift is allowed
        // through below so shifted symbols/arrows still work.
        guard mods.subtracting(.shift).isEmpty else { return .passThrough }

        switch key {
        case .leftArrow: return .moveSelection(-1)
        case .rightArrow: return .moveSelection(1)
        case .deleteForward: return .deleteSelectedCard       // ⌦ deletes a card; plain ⌫ does not
        case .space:
            // Peek the selected card. IME composition is handled UPSTREAM (the controller bails on
            // marked text), so a Space that commits a candidate never reaches here. With nothing
            // selected (empty results) the space just types.
            return state.hasSelection ? .toggleQuickLook : .passThrough
        default:
            return .passThrough                               // printable keys, ⌫, etc. edit the search
        }
    }
}
