import AppKit
import ApplicationServices

struct PasteTargetSnapshot {
    let application: NSRunningApplication
    let processIdentifier: pid_t
    let localizedName: String
    let bundleIdentifier: String?
    let focusedElement: AXUIElement?
    let capturedAt: Date

    static func capture(excluding excludedBundleIdentifier: String?) -> PasteTargetSnapshot? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        guard application.bundleIdentifier != excludedBundleIdentifier else { return nil }
        return PasteTargetSnapshot(
            application: application,
            processIdentifier: application.processIdentifier,
            localizedName: application.localizedName ?? "Unknown",
            bundleIdentifier: application.bundleIdentifier,
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
        return (focusedElement as! AXUIElement)
    }

    private static func isElementValid(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
    }
}

enum PasteStrategy: String {
    case accessibilitySelectedText
    case accessibilityValueRange
    case pasteboardOnly
    case pasteboardKeystroke
}

struct PasteExecutionResult {
    let strategy: PasteStrategy
    let success: Bool
    let detail: String
}

@MainActor
final class PasteExecutor {
    static let shared = PasteExecutor()

    func paste(item: ClipboardItem, target: PasteTargetSnapshot?) async -> PasteExecutionResult {
        guard isAccessibilityTrusted(promptIfNeeded: true) else {
            return PasteExecutionResult(
                strategy: .pasteboardOnly,
                success: false,
                detail: "Accessibility permission is not granted; copied item to pasteboard only."
            )
        }

        guard let target, target.isFresh else {
            // Fallback (no fresh AX target). The panel was ordered out before paste, but
            // ClipDeck can still be the active app, so a blind Cmd+V would land on nothing.
            // Hand focus off first — symmetric with the success path's bringTargetToFront.
            if let target {
                await bringTargetToFront(target)
            } else {
                NSApp.deactivate()
            }
            let keystrokeSent = sendPasteKeystroke()
            return PasteExecutionResult(
                strategy: .pasteboardKeystroke,
                success: keystrokeSent,
                detail: keystrokeSent
                    ? "No fresh paste target snapshot; refocused target and sent fallback Cmd+V."
                    : "No fresh paste target snapshot and Cmd+V synthesis failed; pasteboard only."
            )
        }

        await bringTargetToFront(target)

        if item.kind != .image {
            if let element = target.resolvedFocusedElement() {
                // Prefer replacing the current selection (AXSelectedText) over rewriting
                // the entire field value (AXValue), which is heavier and can clobber rich
                // formatting in capable text controls.
                let selectedTextResult = insertViaSelectedText(item.text, into: element)
                if selectedTextResult == .success {
                    return PasteExecutionResult(
                        strategy: .accessibilitySelectedText,
                        success: true,
                        detail: "Inserted text through AXSelectedText into \(target.localizedName)."
                    )
                }

                let valueRangeResult = insertViaValueRange(item.text, into: element)
                if valueRangeResult == .success {
                    return PasteExecutionResult(
                        strategy: .accessibilityValueRange,
                        success: true,
                        detail: "Inserted text through AXValue/AXSelectedTextRange into \(target.localizedName)."
                    )
                }

                debugLog("ClipDeck AX paste failed for \(target.localizedName): selectedText=\(selectedTextResult.rawValue), valueRange=\(valueRangeResult.rawValue)")
            } else {
                debugLog("ClipDeck AX paste skipped for \(target.localizedName): no focused element")
            }
        }

        let keystrokeSent = sendPasteKeystroke()
        return PasteExecutionResult(
            strategy: .pasteboardKeystroke,
            success: keystrokeSent,
            detail: keystrokeSent
                ? "Sent fallback Cmd+V to \(target.localizedName)."
                : "Failed to synthesize Cmd+V; left content on the pasteboard only."
        )
    }

    private func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        if AccessibilityPermission.isTrusted {
            return true
        }
        guard promptIfNeeded else { return false }
        return AccessibilityPermission.requestIfNeeded()
    }

    private func bringTargetToFront(_ target: PasteTargetSnapshot) async {
        target.application.activate(options: [])
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        let deadline = Date().addingTimeInterval(0.60)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
                break
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        if let element = target.resolvedFocusedElement() {
            AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    private func insertViaSelectedText(_ text: String, into element: AXUIElement) -> AXError {
        guard isAttributeSettable(kAXSelectedTextAttribute as CFString, in: element) else {
            return .attributeUnsupported
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
    }

    private func insertViaValueRange(_ text: String, into element: AXUIElement) -> AXError {
        guard isAttributeSettable(kAXValueAttribute as CFString, in: element) else {
            return .attributeUnsupported
        }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let currentValue = valueRef as? String else {
            return .noValue
        }

        let selectedRange = selectedTextRange(in: element) ?? CFRange(location: currentValue.utf16.count, length: 0)
        guard let nextValue = Self.replacingText(in: currentValue, selectedRange: selectedRange, with: text) else {
            return .illegalArgument
        }

        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            nextValue as CFString
        )
        guard setValueResult == .success else { return setValueResult }

        let nextCursorLocation = selectedRange.location + text.utf16.count
        var nextRange = CFRange(location: nextCursorLocation, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &nextRange) {
            AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
        }

        return .success
    }

    private func selectedTextRange(in element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeValue = rangeRef,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue((rangeValue as! AXValue), .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func isAttributeSettable(_ attribute: CFString, in element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &isSettable) == .success && isSettable.boolValue
    }

    @discardableResult
    private func sendPasteKeystroke() -> Bool {
        // Aligned with Maccy/Clipy's proven approach:
        // - .combinedSessionState event source + suppressing local keyboard events so
        //   modifier keys the user is still holding don't pollute the synthesized ⌘V.
        // - command flag plus 0x8 (a compatibility bit Flycut introduced and Maccy carries).
        // - posted to the session event tap (delivers to the current session's focus).
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.v, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: KeyCode.v, keyDown: false) else {
            return false
        }
        let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008)
        keyDown.flags = commandFlags
        keyUp.flags = commandFlags
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }

    private func debugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
        NSLog("%@", message())
        #endif
    }

    nonisolated static func replacingText(in value: String, selectedRange: CFRange, with replacement: String) -> String? {
        guard selectedRange.location >= 0, selectedRange.length >= 0 else { return nil }

        let utf16 = value.utf16
        guard let startUTF16 = utf16.index(
            utf16.startIndex,
            offsetBy: selectedRange.location,
            limitedBy: utf16.endIndex
        ),
              let endUTF16 = utf16.index(
                startUTF16,
                offsetBy: selectedRange.length,
                limitedBy: utf16.endIndex
              ),
              let start = String.Index(startUTF16, within: value),
              let end = String.Index(endUTF16, within: value) else {
            return nil
        }

        var nextValue = value
        nextValue.replaceSubrange(start..<end, with: replacement)
        return nextValue
    }
}
