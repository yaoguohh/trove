import AppKit

/// After a clip is dropped onto another app, that app is not necessarily brought to
/// the foreground (the drag originated from a non-activating panel), so the user has
/// to click before typing. This brings the app owning the window under the drop point
/// to the front. It relies only on the public window list + NSRunningApplication —
/// no Accessibility permission and no synthetic clicks.
enum DropTargetActivator {
    static func activateApp(at screenPoint: NSPoint) {
        guard let pid = ownerPID(at: screenPoint),
              pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        _ = app.activate()
    }

    private static func ownerPID(at screenPoint: NSPoint) -> pid_t? {
        // CGWindowList uses top-left-origin global coordinates; AppKit screen points are
        // bottom-left-origin. Flip Y using the primary display (the one anchored at 0,0).
        let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.screens.first)?.frame.height ?? 0
        let cgPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)

        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        // The list is front-to-back; the first normal (layer 0) window containing the
        // point is the topmost one the drop landed on.
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else {
                continue
            }
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            if frame.contains(cgPoint) {
                return pid
            }
        }
        return nil
    }
}
