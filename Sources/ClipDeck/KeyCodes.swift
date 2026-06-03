import Carbon
import CoreGraphics

/// Named virtual key codes, replacing scattered magic numbers (53/123/124/36/76/9)
/// across the panel, paste executor, and settings recorder.
enum KeyCode {
    static let escape = UInt16(kVK_Escape)              // 53
    static let leftArrow = UInt16(kVK_LeftArrow)        // 123
    static let rightArrow = UInt16(kVK_RightArrow)      // 124
    static let upArrow = UInt16(kVK_UpArrow)            // 126
    static let downArrow = UInt16(kVK_DownArrow)        // 125
    static let returnKey = UInt16(kVK_Return)           // 36
    static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter) // 76
    static let delete = UInt16(kVK_Delete)              // 51 — Backspace
    static let n = UInt16(kVK_ANSI_N)                   // 45 — Emacs-style ⌃N (next)
    static let p = UInt16(kVK_ANSI_P)                   // 35 — Emacs-style ⌃P (previous)

    /// CGEvent uses CGKeyCode for synthesized keystrokes.
    static let v = CGKeyCode(kVK_ANSI_V)                // 9
}
