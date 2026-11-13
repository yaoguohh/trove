import AppKit
import SwiftUI

/// Owns the status menu: a hand-positioned borderless panel dropped straight under the menu-bar
/// icon (no NSPopover arrow, like Control Center). It lives only while open, together with a global
/// mouse monitor (dismiss on any outside click, including other menu-bar icons) and a resign-active
/// observer (dismiss on ⌘-Tab / focus loss).
@MainActor
final class StatusMenuController {
    private let store: ClipStore
    private let settings: AppSettings
    private let updater: UpdaterController
    private let hotKeys: HotKeyManager
    private let showPanel: () -> Void

    private var panel: NSPanel?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// When the menu last closed — so the click that dismissed it (via the monitor) doesn't re-open it
    /// when the status-item action fires right after.
    private var lastClosed: Date?

    init(
        store: ClipStore,
        settings: AppSettings,
        updater: UpdaterController,
        hotKeys: HotKeyManager,
        showPanel: @escaping () -> Void
    ) {
        self.store = store
        self.settings = settings
        self.updater = updater
        self.hotKeys = hotKeys
        self.showPanel = showPanel
    }

    func toggle(under button: NSStatusBarButton) {
        if panel != nil {
            close()
            return
        }
        if let lastClosed, Date().timeIntervalSince(lastClosed) < 0.2 { return }
        open(under: button)
    }

    func close() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
        lastClosed = Date()
    }

    private func open(under button: NSStatusBarButton) {
        guard let iconWindow = button.window else { return }
        let view = StatusMenuView(
            settings: settings,
            clipCount: store.items.count,
            version: AppInfo.version,
            accessibilityTrusted: AccessibilityPermission.isTrusted,
            clipboardAccessNeedsAction: ClipboardAccessPermission.needsUserAction,
            shortcutRegistered: hotKeys.isRegistered,
            canCheckForUpdates: updater.canCheckForUpdates,
            onShow: { [weak self] in self?.close(); self?.showPanel() },
            onClearHistory: { [weak self] in
                self?.close()
                guard let store = self?.store, ClearHistoryAlert.confirm() else { return }
                store.clearUnpinned()
            },
            onCheckUpdates: { [weak self] in self?.close(); self?.updater.checkForUpdates() },
            onClose: { [weak self] in self?.close() },
            onGrantAccessibility: { [weak self] in self?.close(); AccessibilityPermission.openSettings() },
            onAllowClipboardAccess: { [weak self] in self?.close(); ClipboardAccessPermission.openSettings() },
            onQuit: { NSApp.terminate(nil) }
        )
        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize

        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                    // follows the rounded glass content -> a rounded shadow
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.hidesOnDeactivate = false           // dismissed explicitly via the resign-active observer
        panel.animationBehavior = .none           // faded in below; dismissal is instant

        // Drop straight down from the icon, centered on it, clamped fully on-screen.
        let iconFrame = iconWindow.frame
        var origin = NSPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.minY - 4 - size.height)
        if let visible = (iconWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        self.panel = panel

        // Activate so the buttons are clickable and Esc (the view's onExitCommand) reaches a key window.
        NSApp.activate()
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.fadeIn()

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }
}
