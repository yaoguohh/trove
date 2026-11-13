import AppKit
import Carbon

/// The global shortcut that summons the panel: a virtual key code plus Carbon modifier masks.
struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let defaultShowPanel = HotKeyShortcut(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey))

    /// Ordered key-cap symbols (⌃ ⌥ ⇧ ⌘ then the key) for a badge-style display.
    @MainActor
    var symbols: [String] {
        ModifierKey.symbols(carbon: carbonModifiers) + [KeyCodeNames.symbol(for: keyCode)]
    }

    /// The shortcut a key press in the recorder describes; nil without at least one modifier.
    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    init?(event: NSEvent) {
        let carbonModifiers = ModifierKey.carbon(from: event.modifierFlags)
        guard carbonModifiers != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: carbonModifiers)
    }
}

/// The four shortcut modifiers in display order, with their Carbon masks and symbols — the one table
/// behind the shortcut badges, the recorder's live modifiers and hotkey registration.
enum ModifierKey: CaseIterable {
    case control, option, shift, command

    var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .control: .control
        case .option: .option
        case .shift: .shift
        case .command: .command
        }
    }

    var carbonMask: UInt32 {
        switch self {
        case .control: UInt32(controlKey)
        case .option: UInt32(optionKey)
        case .shift: UInt32(shiftKey)
        case .command: UInt32(cmdKey)
        }
    }

    static func carbon(from flags: NSEvent.ModifierFlags) -> UInt32 {
        allCases.filter { flags.contains($0.flag) }.reduce(0) { $0 | $1.carbonMask }
    }

    static func symbols(carbon: UInt32) -> [String] {
        allCases.filter { carbon & $0.carbonMask != 0 }.map(\.symbol)
    }

    static func symbols(flags: NSEvent.ModifierFlags) -> [String] {
        allCases.filter { flags.contains($0.flag) }.map(\.symbol)
    }
}
