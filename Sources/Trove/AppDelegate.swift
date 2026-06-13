import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = ClipboardStore()
    private let shortcutStore = ShortcutStore()
    private var monitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    /// Global mouse monitor live only while the status menu is open, so a click on ANY other menu-bar
    /// icon (or anywhere outside the app) dismisses it — the gap `.transient` leaves on the menu bar.
    private var statusPopoverMonitor: Any?
    private var panelController: ClipboardPanelController?
    private var updaterController: UpdaterController?
    private let runInBackgroundKey = "Trove.runInBackground"

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceManager.apply()
        applyActivationPolicy()
        let clipboardMonitor = ClipboardMonitor(store: store)
        monitor = clipboardMonitor
        clipboardMonitor.start()

        panelController = ClipboardPanelController(
            store: store,
            monitor: clipboardMonitor
        )
        hotKeyManager = HotKeyManager { [weak self] in
            self?.togglePanel()
        }
        hotKeyManager?.register(shortcut: shortcutStore.shortcut)
        shortcutStore.onChange = { [weak self] shortcut in
            self?.hotKeyManager?.register(shortcut: shortcut)
        }
        // Sparkle auto-updates: starts scheduled background checks (release builds only — the
        // updater runtime lives in the packaged .app's embedded Sparkle.framework).
        updaterController = UpdaterController()

        configureMenuBar()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Flush any debounced save synchronously so we never lose recent history.
        store.flush()
    }

    private func configureMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Trove")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Left click toggles the panel; right/control click opens the status menu. Assigning
        // `item.menu` directly would suppress the action entirely, so we present the menu (a designed
        // SwiftUI popover) on demand instead.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private var runsInBackground: Bool {
        // Default to background (menu-bar only, no Dock icon), like Maccy / Ice — but honor an
        // explicit choice once the user has toggled it. `object(forKey:)` is nil until then.
        UserDefaults.standard.object(forKey: runInBackgroundKey) as? Bool ?? true
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(runsInBackground ? .accessory : .regular)
    }

    private func togglePanel() {
        if panelController?.isVisible == true {
            panelController?.hide(animated: true)
        } else {
            monitor?.rememberPasteTarget()
            panelController?.show()
        }
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func showStatusMenu() {
        guard let button = statusItem?.button else { return }
        if let existing = statusPopover, existing.isShown {
            existing.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let view = StatusMenuView(
            clipCount: store.matches(query: "").count,
            version: Self.appVersion,
            accessibilityTrusted: AccessibilityPermission.isTrusted,
            shortcutStore: shortcutStore,
            linkPreviewsOn: LinkMetadataProvider.isAutoFetchEnabled,
            runInBackground: runsInBackground,
            onShow: { [weak self] in self?.closeStatusPopover(); self?.showPanel() },
            onToggleLinkPreviews: { [weak self] in self?.toggleLinkPreviews() },
            onToggleBackground: { [weak self] in self?.toggleBackgroundMode() },
            onClearHistory: { [weak self] in self?.closeStatusPopover(); self?.clearUnpinned() },
            onCheckUpdates: { [weak self] in self?.closeStatusPopover(); self?.checkForUpdates(nil) },
            onClose: { [weak self] in self?.closeStatusPopover() },
            onGrantAccessibility: { [weak self] in self?.closeStatusPopover(); self?.openAccessibilitySettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        let hosting = NSHostingController(rootView: view)
        popover.contentViewController = hosting
        // Size the popover to the content's real fitting size up front. Left at the default 320×320, a
        // taller menu gets positioned for 320pt and then grows to its true height by expanding UPWARD,
        // pushing its top off the screen on a menu-bar (top-of-screen) status item. With the correct
        // size known before `show`, macOS anchors it cleanly below the icon, fully on-screen.
        popover.contentSize = hosting.view.fittingSize
        statusPopover = popover
        // Accessory apps must activate so the popover's buttons are clickable and it dismisses on an
        // outside click; the status menu isn't paste-related, so activating here is harmless.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // `.transient` dismisses on clicks into other WINDOWS, but not when the user clicks a different
        // menu-bar icon (the system menu-bar area) — more so since we activated above. A global
        // mouse-down monitor closes the menu on any click outside the app, covering that gap. Clicks
        // INSIDE the popover stay local to the app, so they don't trip this and the menu stays open.
        statusPopoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeStatusPopover()
        }
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
        teardownStatusPopover()
    }

    /// Single teardown chokepoint: also runs on `.transient`'s own outside-click dismissal (via
    /// `popoverDidClose`), so the global monitor is never left installed across opens.
    func popoverDidClose(_ notification: Notification) {
        teardownStatusPopover()
    }

    private func teardownStatusPopover() {
        if let monitor = statusPopoverMonitor {
            NSEvent.removeMonitor(monitor)
            statusPopoverMonitor = nil
        }
        statusPopover = nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    @objc private func showPanel() {
        monitor?.rememberPasteTarget()
        panelController?.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    @objc private func clearUnpinned() {
        store.clearUnpinned()
    }

    @objc private func toggleLinkPreviews() {
        LinkMetadataProvider.isAutoFetchEnabled.toggle()
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    @objc private func toggleBackgroundMode() {
        UserDefaults.standard.set(!runsInBackground, forKey: runInBackgroundKey)
        applyActivationPolicy()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
