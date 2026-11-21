import AppKit
import SwiftUI

/// The welcome window: on a fresh install it introduces Trove and its two permissions; later it comes
/// back once per launch when a paste could only copy because Accessibility is missing. Permission
/// state in it updates live; once the guide sees Accessibility granted, the window comes back to the
/// front with that row checked off.
@MainActor
final class WelcomeController: NSObject, NSWindowDelegate {
    enum Reason {
        case firstLaunch
        case pasteNeedsAccessibility
    }

    private let guide: PermissionGuide
    private let settings: AppSettings
    private let status = PermissionStatus()
    private var window: NSWindow?
    private var shownForPaste = false

    init(guide: PermissionGuide, settings: AppSettings) {
        self.guide = guide
        self.settings = settings
        super.init()
        guide.onGranted = { [weak self] in self?.bringToFront() }
    }

    /// Only a fresh install gets the welcome on its own: someone upgrading already knows Trove, and the
    /// status menu and the paste path still point them at a missing permission.
    nonisolated static func showsAtLaunch(seen: Bool, historyIsEmpty: Bool) -> Bool {
        !seen && historyIsEmpty
    }

    func showAtLaunchIfNeeded(historyIsEmpty: Bool) {
        guard Self.showsAtLaunch(seen: settings.welcomeSeen, historyIsEmpty: historyIsEmpty) else { return }
        show(.firstLaunch)
    }

    /// At most once per launch, so repeated pastes don't keep pulling the window up; the status menu
    /// keeps the reminder.
    func showForPaste() {
        guard !shownForPaste else { return }
        shownForPaste = true
        show(.pasteNeedsAccessibility)
    }

    func show(_ reason: Reason) {
        settings.welcomeSeen = true
        let view = WelcomeView(
            reason: reason,
            shortcut: settings.shortcut.symbols.joined(),
            status: status,
            onGrantAccessibility: { [weak self] in
                let mouse = NSEvent.mouseLocation
                self?.guide.guideAccessibility(from: CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32))
            },
            onOpenClipboardSettings: { ClipboardAccessPermission.openSettings() },
            onDone: { [weak self] in self?.window?.close() }
        )
        if let window, let hosting = window.contentViewController as? NSHostingController<WelcomeView> {
            hosting.rootView = view
        } else {
            let hosting = NSHostingController(rootView: view)
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Trove"
            window.backgroundColor = NSColor(Theme.Surface.coal)
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.center()
            self.window = window
        }
        status.startWatching()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        status.stopWatching()
        window = nil
    }

    private func bringToFront() {
        guard let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
