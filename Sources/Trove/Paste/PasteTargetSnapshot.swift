import AppKit

/// The app a paste will land in, captured when the panel is summoned (while that app is still
/// frontmost), with its focused element for Accessibility insertion.
struct PasteTargetSnapshot {
    let application: NSRunningApplication
    let processIdentifier: pid_t
    let localizedName: String
    let focusedElement: AXUIElement?
    let capturedAt: Date

    static func capture(excluding excludedBundleIdentifier: String?) -> PasteTargetSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard application.bundleIdentifier != excludedBundleIdentifier else { return nil }
        return PasteTargetSnapshot(
            application: application,
            processIdentifier: application.processIdentifier,
            localizedName: application.localizedName ?? "Unknown",
            focusedElement: Self.focusedElement(in: application.processIdentifier),
            capturedAt: Date()
        )
    }

    var isFresh: Bool {
        // A visual clipboard browser is often kept open for a while; 20s expired too
        // eagerly and degraded to a blind Cmd+V. 90s keeps the captured target usable.
        Date().timeIntervalSince(capturedAt) < 90
    }

    func resolvedFocusedElement() -> AXUIElement? {
        if let focusedElement, Self.isElementValid(focusedElement) {
            return focusedElement
        }
        return Self.focusedElement(in: processIdentifier)
    }

    static func focusedElement(in processIdentifier: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success,
              let focusedElement,
              CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            return nil
        }
        // CF types have no conditional cast; the type-id check above is what makes this safe.
        return (focusedElement as! AXUIElement)
    }

    private static func isElementValid(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
    }
}
