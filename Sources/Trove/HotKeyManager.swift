import AppKit
import Carbon

struct HotKeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    /// Persisted for compatibility with earlier releases; the UI renders `symbols`.
    var displayName: String

    static let defaultShowPanel = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_V),
        carbonModifiers: UInt32(cmdKey | shiftKey),
        displayName: "⇧⌘V"
    )

    init(keyCode: UInt32, carbonModifiers: UInt32, displayName: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayName = displayName
    }

    /// Ordered key-cap symbols (⌃ ⌥ ⇧ ⌘ then the key) for a badge-style display.
    @MainActor
    var symbols: [String] {
        ModifierKey.symbols(carbon: carbonModifiers) + [KeyCodeNames.symbol(for: keyCode)]
    }

    /// The shortcut a key press in the recorder describes; nil without at least one modifier.
    @MainActor
    init?(event: NSEvent) {
        let carbonModifiers = ModifierKey.carbon(from: event.modifierFlags)
        guard carbonModifiers != 0 else { return nil }
        let keyCode = UInt32(event.keyCode)
        let symbols = ModifierKey.symbols(carbon: carbonModifiers) + [KeyCodeNames.symbol(for: keyCode)]
        self.init(keyCode: keyCode, carbonModifiers: carbonModifiers, displayName: symbols.joined())
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
    /// False when the last registration failed — typically another app already owns the combination.
    /// The status menu shows it next to the shortcut.
    private(set) var isRegistered = false

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

        isRegistered = registerHotKey(id: HotKeyManager.showPanelHotKeyID, keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers)
    }

    private func registerHotKey(id: UInt32, keyCode: UInt32, modifiers: UInt32) -> Bool {
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
        guard status == noErr, let ref else {
            Log.hotkey.error("failed to register hotkey \(id): \(status)")
            return false
        }
        hotKeyRefs.append(ref)
        return true
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
