import AppKit
import ApplicationServices
import Carbon  // ProcessSerialNumber (Process Manager) for front-window-only activation

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

        // Full text (sidecar-backed for big clips), read once. Images can't be AX-inserted.
        let full = item.kind != .image ? item.fullText : nil

        // Fast path: insert via the Accessibility API WITHOUT activating the target app. Activating an
        // app brings its windows forward — that's why a user with many browser windows sees the OTHER
        // ones jump to the top after a paste. AX text insertion into the captured focused element does
        // not need the app frontmost, so try it first; on success, window order is never touched. Only
        // when AX can't insert (notably secure password fields) do we fall back to activating + Cmd+V.
        if let target, target.isFresh, let full,
           let result = accessibilityInsert(full, into: target) {
            return result
        }

        guard let target, target.isFresh else {
            // Fallback (no fresh AX target). The panel was ordered out before paste, but
            // Trove can still be the active app, so a blind Cmd+V would land on nothing.
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

        // AX insertion didn't take while the target was in the background — secure password fields (and
        // some browser web content) only accept it, if at all, when frontmost. Bring the target forward
        // (front-window-only, so the app's OTHER windows are not raised) and retry AX before the Cmd+V
        // keystroke fallback.
        await bringTargetToFront(target)

        if let full, let result = accessibilityInsert(full, into: target) {
            return result
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

    /// Insert `full` into the target's focused element via Accessibility, returning a successful result
    /// or nil if there's no focused element / AX couldn't insert (the caller then escalates). Critically,
    /// this does NOT activate the app or change window order — that's why it's tried before
    /// `bringTargetToFront`, so a successful paste leaves the user's other windows untouched.
    private func accessibilityInsert(_ full: String, into target: PasteTargetSnapshot) -> PasteExecutionResult? {
        guard let element = target.resolvedFocusedElement() else {
            debugLog("Trove AX paste skipped for \(target.localizedName): no focused element")
            return nil
        }
        // Prefer replacing the current selection (AXSelectedText) over rewriting the entire field value
        // (AXValue), which is heavier and can clobber rich formatting in capable text controls.
        let selectedTextResult = insertViaSelectedText(full, into: element)
        if selectedTextResult == .success {
            return PasteExecutionResult(
                strategy: .accessibilitySelectedText,
                success: true,
                detail: "Inserted text through AXSelectedText into \(target.localizedName)."
            )
        }

        let valueRangeResult = insertViaValueRange(full, into: element)
        if valueRangeResult == .success {
            return PasteExecutionResult(
                strategy: .accessibilityValueRange,
                success: true,
                detail: "Inserted text through AXValue/AXSelectedTextRange into \(target.localizedName)."
            )
        }

        debugLog("Trove AX paste failed for \(target.localizedName): selectedText=\(selectedTextResult.rawValue), valueRange=\(valueRangeResult.rawValue)")
        return nil
    }

    private func isAccessibilityTrusted(promptIfNeeded: Bool) -> Bool {
        if AccessibilityPermission.isTrusted {
            return true
        }
        guard promptIfNeeded else { return false }
        return AccessibilityPermission.requestIfNeeded()
    }

    private func bringTargetToFront(_ target: PasteTargetSnapshot) async {
        // NSRunningApplication.activate(options:[]) has a Big-Sur-onward regression: it raises ALL of
        // the app's windows (as if .activateAllWindows were always set) instead of just the main/key
        // window. That is what makes a user's OTHER browser windows jump to the top when Trove must
        // activate to deliver a Cmd+V — the password-field path, where AX text insertion is blocked by
        // the secure field. Use the Carbon Process Manager's front-window-only activation, which makes
        // the app key for keyboard input but raises ONLY its frontmost window — the documented community
        // workaround for this exact bug. (Also drop the app-level kAXFrontmostAttribute set, which had
        // the same raise-everything side effect.) Falls back to NSRunningApplication if unavailable.
        if !activateFrontWindowOnly(pid: target.processIdentifier) {
            target.application.activate(options: [])
        }

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

    /// Activate `pid`'s app for keyboard input while raising ONLY its frontmost window (not every window
    /// the app owns) — the standard workaround for the `NSRunningApplication.activate` "raises all
    /// windows" regression. The Carbon Process Manager calls it needs (`GetProcessForPID`,
    /// `SetFrontProcessWithOptions`) are marked *unavailable* in Swift (not merely deprecated), so they
    /// are resolved at runtime via `dlsym` — Carbon is linked into the process, so the symbols are
    /// present. Returns false on any failure so the caller can fall back to `NSRunningApplication`.
    private func activateFrontWindowOnly(pid: pid_t) -> Bool {
        typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
        typealias SetFrontProcessFn = @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32) -> OSStatus
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT: search all loaded images
        guard let getSym = dlsym(rtldDefault, "GetProcessForPID"),
              let setSym = dlsym(rtldDefault, "SetFrontProcessWithOptions") else {
            return false
        }
        let getProcessForPID = unsafeBitCast(getSym, to: GetProcessForPIDFn.self)
        let setFrontProcess = unsafeBitCast(setSym, to: SetFrontProcessFn.self)
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        // kSetFrontProcessFrontWindowOnly == 1: activate for input, raise only the frontmost window.
        return setFrontProcess(&psn, 1) == noErr
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
        // Aligned with Maccy/Clipy's approach: a .combinedSessionState source, the Flycut/Maccy
        // command+0x8 compatibility flag, posted to the session event tap (the current session's focus).
        //
        // Crucially we do NOT suppress the user's real keyboard around the synthesized ⌘V. The events
        // below carry explicit, clean flags, so the held-modifier pollution the suppression used to guard
        // against is already handled — whereas the default ~0.25s suppression interval (with a mask that
        // omitted keyboard) would DROP a real Cmd+C the user happens to press just after pasting from
        // Trove, silently losing their copy. So permit local keyboard events AND zero the interval.
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        source?.localEventsSuppressionInterval = 0
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
