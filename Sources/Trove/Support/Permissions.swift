import AppKit

/// Accessibility lets Trove post ⌘V into the app it pastes into (and insert text there directly when
/// that app isn't frontmost). Without it a paste only puts the clip on the pasteboard. Trove never
/// raises the system's own prompt: the welcome window's guide (`PermissionGuide`) walks the user
/// through System Settings instead.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }
}

/// macOS 15.4+ asks the user before an app reads the general pasteboard programmatically, which is
/// all Trove's history does. Until the user picks "Always Allow" for Trove, copies are either
/// prompted for or (when denied) silently missing from history.
enum ClipboardAccessPermission {
    /// Whether this macOS has the setting at all.
    static var isAvailable: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    /// True when the user has to act in System Settings for history to keep up: Trove is listed
    /// there as "Ask" or "Deny". (`.default` means the system has not prompted yet; there is
    /// nothing to change until it has.)
    @MainActor
    static var needsUserAction: Bool {
        guard #available(macOS 15.4, *) else { return false }
        switch NSPasteboard.general.accessBehavior {
        case .ask, .alwaysDeny: return true
        default: return false
        }
    }

    /// True only once the user has allowed Trove in System Settings; the welcome window checks this
    /// row off only then.
    @MainActor
    static var isAllowed: Bool {
        guard #available(macOS 15.4, *) else { return true }
        return NSPasteboard.general.accessBehavior == .alwaysAllow
    }

    @MainActor
    static var logDescription: String {
        guard #available(macOS 15.4, *) else { return "unsupported" }
        switch NSPasteboard.general.accessBehavior {
        case .default: return "default"
        case .ask: return "ask"
        case .alwaysAllow: return "alwaysAllow"
        case .alwaysDeny: return "alwaysDeny"
        @unknown default: return "unknown"
        }
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") else { return }
        NSWorkspace.shared.open(url)
    }
}
