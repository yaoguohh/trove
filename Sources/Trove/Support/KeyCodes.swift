import Carbon

/// Named virtual key codes used by the panel's key routing, the shortcut recorder and the paste
/// keystroke.
enum KeyCode {
    static let escape = UInt16(kVK_Escape)
    static let leftArrow = UInt16(kVK_LeftArrow)
    static let rightArrow = UInt16(kVK_RightArrow)
    static let returnKey = UInt16(kVK_Return)
    static let keypadEnter = UInt16(kVK_ANSI_KeypadEnter)
    static let delete = UInt16(kVK_Delete)               // Backspace
    static let forwardDelete = UInt16(kVK_ForwardDelete) // ⌦ / fn+Delete (delete a card)
    static let space = UInt16(kVK_Space)                 // peek bubble

    /// CGEvent uses CGKeyCode for synthesized keystrokes.
    static let v = CGKeyCode(kVK_ANSI_V)
}

/// The key-cap symbol for a virtual key code. Keys that print nothing get a fixed symbol; every other
/// key shows the character it types in the user's current keyboard layout, so a shortcut recorded
/// on AZERTY or Dvorak reads the way the keyboard is labelled.
@MainActor
enum KeyCodeNames {
    static func symbol(for keyCode: UInt32) -> String {
        if let fixed = fixedSymbols[Int(keyCode)] { return fixed }
        return layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
    }

    private static let fixedSymbols: [Int: String] = [
        kVK_Space: "␣", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// What the key types with no modifiers in the current layout (an input method such as Pinyin
    /// reports its underlying keyboard layout), upper-cased like a key cap.
    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        guard let source,
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = layoutData.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count, &length, &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let character = String(utf16CodeUnits: characters, count: length)
        guard !character.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).isEmpty else { return nil }
        return character.uppercased()
    }
}
