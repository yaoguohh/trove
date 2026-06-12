import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let shortcutStore = ShortcutStore()
    private var monitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var statusPopover: NSPopover?
    private var panelController: ClipboardPanelController?
    private var settingsController: SettingsPanelController?
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
            monitor: clipboardMonitor,
            onOpenSettings: { [weak self] in self?.showPreferences() }
        )
        hotKeyManager = HotKeyManager { [weak self] in
            self?.togglePanel()
        }
        hotKeyManager?.register(shortcut: shortcutStore.shortcut)
        shortcutStore.onChange = { [weak self] shortcut in
            self?.hotKeyManager?.register(shortcut: shortcut)
        }
        settingsController = SettingsPanelController(shortcutStore: shortcutStore)
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
        let view = StatusMenuView(
            clipCount: store.matches(query: "").count,
            version: Self.appVersion,
            accessibilityTrusted: AccessibilityPermission.isTrusted,
            linkPreviewsOn: LinkMetadataProvider.isAutoFetchEnabled,
            runInBackground: runsInBackground,
            onShow: { [weak self] in self?.closeStatusPopover(); self?.showPanel() },
            onToggleLinkPreviews: { [weak self] in self?.toggleLinkPreviews() },
            onToggleBackground: { [weak self] in self?.toggleBackgroundMode() },
            onClearHistory: { [weak self] in self?.closeStatusPopover(); self?.clearUnpinned() },
            onCheckUpdates: { [weak self] in self?.closeStatusPopover(); self?.checkForUpdates(nil) },
            onPreferences: { [weak self] in self?.closeStatusPopover(); self?.showPreferences() },
            onGrantAccessibility: { [weak self] in self?.closeStatusPopover(); self?.openAccessibilitySettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        statusPopover = popover
        // Accessory apps need to activate so the popover's buttons are clickable and it dismisses on
        // an outside click; the status menu isn't paste-related, so activating here is harmless.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func closeStatusPopover() {
        statusPopover?.performClose(nil)
        statusPopover = nil
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    @objc private func showPanel() {
        monitor?.rememberPasteTarget()
        panelController?.show()
    }

    @objc private func showPreferences() {
        // Close the floating panel before opening Settings. The panel is `.floating` while the
        // Settings window is a normal-level window, so leaving the panel up would (a) hide Settings
        // behind it and (b) strand the panel on screen — with the global Esc monitor gone, only the
        // panel's own key window can Esc-dismiss it, and Settings steals key. Closing here routes
        // ALL entry points (status menu, ⌘, shortcut, and the in-panel menu) through one consistent
        // behavior, matching the transient-panel model: navigating to Settings dismisses the panel.
        panelController?.hide()
        settingsController?.show()
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
