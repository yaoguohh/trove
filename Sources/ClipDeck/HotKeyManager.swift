import Carbon
import AppKit
import Foundation

struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var displayName: String

    static let defaultShowPanel = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayName: "Shift+⌘V"
    )

    init(keyCode: UInt32, carbonModifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayName = displayName
    }

    /// Ordered key-cap symbols (⌃ ⌥ ⇧ ⌘ then the key) for a badge-style display.
    var symbols: [String] {
        var result: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { result.append("⌃") }
        if carbonModifiers & UInt32(optionKey) != 0 { result.append("⌥") }
        if carbonModifiers & UInt32(shiftKey) != 0 { result.append("⇧") }
        if carbonModifiers & UInt32(cmdKey) != 0 { result.append("⌘") }
        result.append(KeyCodeNames.symbol(for: keyCode))
        return result
    }

    init?(event: NSEvent) {
        let keyCode = UInt32(event.keyCode)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        var parts: [String] = []

        if flags.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
            parts.append("Control")
        }
        if flags.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
            parts.append("Option")
        }
        if flags.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
            parts.append("Shift")
        }
        if flags.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
            parts.append("⌘")
        }

        guard carbonModifiers != 0 else { return nil }
        let key = event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)"
        parts.append(key)
        self.init(keyCode: keyCode, carbonModifiers: carbonModifiers, displayName: parts.joined(separator: "+"))
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published private(set) var shortcut: HotKeyShortcut {
        didSet {
            save()
            onChange?(shortcut)
        }
    }

    var onChange: ((HotKeyShortcut) -> Void)?

    private let defaultsKey = "ClipDeck.showPanelShortcut"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        if
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? decoder.decode(HotKeyShortcut.self, from: data)
        {
            shortcut = decoded
        } else {
            shortcut = .defaultShowPanel
        }
    }

    func update(_ shortcut: HotKeyShortcut) {
        self.shortcut = shortcut
    }

    func reset() {
        shortcut = .defaultShowPanel
    }

    private func save() {
        guard let data = try? encoder.encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

/// `@unchecked Sendable` invariant: the only mutable state (`hotKeyRefs`,
/// `handlerRef`) is mutated exclusively from `register()`/`deinit`, both driven from
/// the main thread by `AppDelegate`. The Carbon C event handler runs on the main
/// run loop, reads `self` via an unretained `Unmanaged` pointer, and immediately
/// re-dispatches `action()` onto the main queue — it never touches the mutable
/// state. A `@MainActor` class cannot satisfy Carbon's non-isolated C callback
/// signature, so the contract is enforced by this discipline rather than the
/// compiler.
final class HotKeyManager: @unchecked Sendable {
    /// Single source of truth for the hot key identifier, shared by registration and the
    /// C event handler's comparison so the contract can't silently drift.
    private static let showPanelHotKeyID: UInt32 = 1

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register(shortcut: HotKeyShortcut) {
        unregisterHotKeys()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        if handlerRef == nil {
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                if hotKeyID.id == HotKeyManager.showPanelHotKeyID {
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    DispatchQueue.main.async {
                        manager.action()
                    }
                }
                return noErr
            }, 1, &eventType, selfPointer, &handlerRef)
        }

        registerHotKey(id: HotKeyManager.showPanelHotKeyID, keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers)
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: FourCharCode("CLPD"), id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            NSLog("ClipDeck failed to register hotkey \(id): \(status)")
        }
    }

    private func unregisterHotKeys() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
    }

    deinit {
        unregisterHotKeys()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}

private func FourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
}

/// Maps a virtual key code to a human-readable key-cap symbol.
enum KeyCodeNames {
    static func symbol(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: "A"
        case kVK_ANSI_B: "B"
        case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"
        case kVK_ANSI_E: "E"
        case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"
        case kVK_ANSI_H: "H"
        case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"
        case kVK_ANSI_K: "K"
        case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"
        case kVK_ANSI_N: "N"
        case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"
        case kVK_ANSI_Q: "Q"
        case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"
        case kVK_ANSI_T: "T"
        case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"
        case kVK_ANSI_W: "W"
        case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"
        case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"
        case kVK_ANSI_1: "1"
        case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"
        case kVK_ANSI_4: "4"
        case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"
        case kVK_ANSI_7: "7"
        case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_ANSI_Minus: "-"
        case kVK_ANSI_Equal: "="
        case kVK_ANSI_LeftBracket: "["
        case kVK_ANSI_RightBracket: "]"
        case kVK_ANSI_Backslash: "\\"
        case kVK_ANSI_Semicolon: ";"
        case kVK_ANSI_Quote: "'"
        case kVK_ANSI_Comma: ","
        case kVK_ANSI_Period: "."
        case kVK_ANSI_Slash: "/"
        case kVK_ANSI_Grave: "`"
        case kVK_Space: "␣"
        case kVK_Return, kVK_ANSI_KeypadEnter: "↩"
        case kVK_Tab: "⇥"
        case kVK_Escape: "⎋"
        case kVK_Delete: "⌫"
        case kVK_ForwardDelete: "⌦"
        case kVK_LeftArrow: "←"
        case kVK_RightArrow: "→"
        case kVK_UpArrow: "↑"
        case kVK_DownArrow: "↓"
        case kVK_Home: "↖"
        case kVK_End: "↘"
        case kVK_PageUp: "⇞"
        case kVK_PageDown: "⇟"
        case kVK_F1: "F1"
        case kVK_F2: "F2"
        case kVK_F3: "F3"
        case kVK_F4: "F4"
        case kVK_F5: "F5"
        case kVK_F6: "F6"
        case kVK_F7: "F7"
        case kVK_F8: "F8"
        case kVK_F9: "F9"
        case kVK_F10: "F10"
        case kVK_F11: "F11"
        case kVK_F12: "F12"
        default: "Key \(keyCode)"
        }
    }
}
