import AppKit

/// Standard editing-shortcut routing for ClipDeck's windows.
///
/// In a normal Mac app ⌘C/⌘X/⌘V/⌘A work because the **main-menu Edit menu** carries those key
/// equivalents and AppKit routes the matching action (`copy:`, `paste:`, …) to the key window's first
/// responder. ClipDeck deliberately has **no main menu** — it's a menu-bar app, and a menu bar would
/// pop up over the spotlight-style panel whenever it's summoned. Without that menu there's no built-in
/// routing for these shortcuts, so each window forwards them to the responder chain itself via
/// `performKeyEquivalent`. This is the standard escape hatch for menu-bar-only apps, kept in ONE place
/// so the inspect window, the search field, and any future text surface all behave identically.
enum EditingShortcuts {
    /// The standard editing action a plain-⌘ letter maps to, or nil if it isn't one of them. Pure and
    /// table-driven so the mapping is unit-testable apart from the live responder dispatch. ⌘Z is
    /// intentionally absent: the panel already routes it to card-undo, and the inspect window is
    /// read-only.
    static func actionName(forKey key: String) -> String? {
        switch key.lowercased() {
        case "c": return "copy:"
        case "x": return "cut:"
        case "v": return "paste:"
        case "a": return "selectAll:"
        default: return nil
        }
    }

    /// Forward a standard editing shortcut to the key window's first responder, returning true iff some
    /// responder accepted it (e.g. a read-only text view rejects `paste:`/`cut:`, so those fall
    /// through). Only a bare ⌘ + letter is considered, so ⌘←/⌘→/⌘⌫/⌘Z still reach the panel's own
    /// keyboard model untouched.
    @MainActor
    static func route(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers,
              let name = actionName(forKey: key) else { return false }
        return NSApp.sendAction(Selector((name)), to: nil, from: nil)
    }
}
