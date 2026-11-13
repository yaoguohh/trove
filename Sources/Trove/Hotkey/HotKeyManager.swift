import Carbon

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
