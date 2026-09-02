import AppKit
import SwiftUI

/// Bridges a raw AppKit `keyDown` into the SwiftUI key + modifiers that the pure `PanelKeyboard.intent`
/// consumes. The panel routes EVERY key through a window-level monitor (not the search field's
/// `onKeyPress`), so navigation/action keys work no matter which subview holds focus — deleting a card
/// can drop the field's focus, which used to silence the only key handler. Decoding from extracted
/// primitives (keyCode / modifier bits / characters) rather than a live `NSEvent` keeps it pure and
/// makes the whole keyDown→intent path unit-testable.
enum PanelKeyEvent {
    static func decode(keyCode: UInt16, modifierRaw: UInt, characters: String?) -> (key: KeyEquivalent, modifiers: SwiftUI.EventModifiers)? {
        guard let key = keyEquivalent(keyCode: keyCode, characters: characters) else { return nil }
        return (key, modifiers(modifierRaw))
    }

    /// Special keys are matched by VIRTUAL keyCode (layout-independent); everything else falls back to
    /// the typed character, which is all `intent` needs (it only treats "z"/"Z" specially, for ⌘Z).
    static func keyEquivalent(keyCode: UInt16, characters: String?) -> KeyEquivalent? {
        switch keyCode {
        case KeyCode.escape: return .escape
        case KeyCode.leftArrow: return .leftArrow
        case KeyCode.rightArrow: return .rightArrow
        case KeyCode.returnKey: return .return
        case KeyCode.keypadEnter: return KeyEquivalent("\u{0003}") // ETX — intent maps it to Return
        case KeyCode.forwardDelete: return .deleteForward          // ⌦ deletes a card
        case KeyCode.delete: return .delete                        // ⌫ (only ⌘⌫ acts; plain ⌫ edits text)
        case KeyCode.space: return .space
        default:
            guard let character = characters?.first else { return nil }
            return KeyEquivalent(character)
        }
    }

    static func modifiers(_ rawValue: UInt) -> SwiftUI.EventModifiers {
        let flags = NSEvent.ModifierFlags(rawValue: rawValue)
        var modifiers: SwiftUI.EventModifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
    }
}
