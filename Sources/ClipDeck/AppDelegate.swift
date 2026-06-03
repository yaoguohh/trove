import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let shortcutStore = ShortcutStore()
    private var monitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var backgroundModeMenuItem: NSMenuItem?
    private var accessibilityMenuItem: NSMenuItem?
    private var linkPreviewMenuItem: NSMenuItem?
    private var panelController: ClipboardPanelController?
    private var settingsController: SettingsPanelController?
    private var updaterController: UpdaterController?
    private let runInBackgroundKey = "ClipDeck.runInBackground"

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
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipDeck")
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Left click toggles the panel; right/control click opens the menu. Assigning
        // `item.menu` directly would suppress the action entirely, so we present the
        // menu on demand instead.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: String(localized: "Show ClipDeck"), action: #selector(showPanel), keyEquivalent: ""))

        // Only shown as a call to action when permission is missing (hidden once granted).
        let accessibilityItem = NSMenuItem(
            title: "",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessibilityMenuItem = accessibilityItem
        menu.addItem(accessibilityItem)
        updateAccessibilityMenuItem()

        menu.addItem(.separator())

        // Toggles: stable title, checkmark indicates the feature is ON.
        let linkPreviewItem = NSMenuItem(title: "", action: #selector(toggleLinkPreviews), keyEquivalent: "")
        linkPreviewMenuItem = linkPreviewItem
        menu.addItem(linkPreviewItem)
        updateLinkPreviewMenuItem()

        let backgroundItem = NSMenuItem(title: "", action: #selector(toggleBackgroundMode), keyEquivalent: "")
        backgroundModeMenuItem = backgroundItem
        menu.addItem(backgroundItem)
        updateBackgroundModeMenuItem()

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: String(localized: "Clear History"), action: #selector(clearUnpinned), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Check for Updates..."), action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: String(localized: "Preferences..."), action: #selector(showPreferences), keyEquivalent: ","))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: String(localized: "Quit ClipDeck"), action: #selector(quit), keyEquivalent: "q"))
        statusMenu = menu
    }

    private var runsInBackground: Bool {
        UserDefaults.standard.bool(forKey: runInBackgroundKey)
    }

    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(runsInBackground ? .accessory : .regular)
    }

    private func updateBackgroundModeMenuItem() {
        guard let backgroundModeMenuItem else { return }
        backgroundModeMenuItem.title = String(localized: "Run in Background")
        backgroundModeMenuItem.state = runsInBackground ? .on : .off
    }

    private func togglePanel() {
        if panelController?.isVisible == true {
            panelController?.hide(animated: true)
        } else {
            updateAccessibilityMenuItem()
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
        guard let button = statusItem?.button, let menu = statusMenu else { return }
        updateAccessibilityMenuItem()
        updateBackgroundModeMenuItem()
        updateLinkPreviewMenuItem()
        let location = NSPoint(x: 0, y: button.bounds.height + 4)
        menu.popUp(positioning: nil, at: location, in: button)
    }

    @objc private func showPanel() {
        updateAccessibilityMenuItem()
        monitor?.rememberPasteTarget()
        panelController?.show()
    }

    @objc private func showPreferences() {
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
        updateLinkPreviewMenuItem()
    }

    private func updateLinkPreviewMenuItem() {
        guard let linkPreviewMenuItem else { return }
        linkPreviewMenuItem.title = String(localized: "Link Previews")
        linkPreviewMenuItem.state = LinkMetadataProvider.isAutoFetchEnabled ? .on : .off
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    @objc private func toggleBackgroundMode() {
        UserDefaults.standard.set(!runsInBackground, forKey: runInBackgroundKey)
        applyActivationPolicy()
        updateBackgroundModeMenuItem()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func updateAccessibilityMenuItem() {
        guard let accessibilityMenuItem else { return }
        // A clean call-to-action only when needed; nothing to show once granted.
        accessibilityMenuItem.isHidden = AccessibilityPermission.isTrusted
        accessibilityMenuItem.title = String(localized: "Grant Accessibility Permission...")
    }
}
