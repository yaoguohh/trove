import AppKit

/// Accessibility lets Trove insert text into the app it pastes into (and, as a fallback, post ⌘V).
/// Without it a paste only puts the clip on the pasteboard.
enum AccessibilityPermission {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt when not yet trusted. Returns whether Trove is trusted now.
    @discardableResult
    static func requestIfNeeded() -> Bool {
        guard !isTrusted else { return true }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        openPrivacyPane("Privacy_Accessibility")
    }
}

/// macOS 15.4+ asks the user before an app reads the general pasteboard programmatically, which is
/// all Trove's history does. Until the user picks "Always Allow" for Trove, copies are either
/// prompted for or (when denied) silently missing from history.
enum ClipboardAccessPermission {
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
        openPrivacyPane("Privacy_Pasteboard")
    }
}

private func openPrivacyPane(_ anchor: String) {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
    NSWorkspace.shared.open(url)
}
