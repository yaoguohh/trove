import AppKit

/// "Clear History" removes every unpinned clip and their files at once, with no undo — so both
/// entry points (status menu and panel) confirm first.
enum ClearHistoryAlert {
    @MainActor
    static func confirm() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Clear History?")
        alert.informativeText = String(localized: "Removes every clip that isn't pinned. This can't be undone.")
        let clear = alert.addButton(withTitle: String(localized: "Clear History"))
        clear.hasDestructiveAction = true
        clear.keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\r"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
