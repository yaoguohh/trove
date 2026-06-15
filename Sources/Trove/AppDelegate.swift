import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ClipboardStore()
    private let shortcutStore = ShortcutStore()
    private var monitor: ClipboardMonitor?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    /// The status menu is a hand-positioned borderless panel (no NSPopover arrow — a clean drop-down
    /// straight under the icon, like Control Center / a `MenuBarExtra(.window)`).
    private var statusMenuPanel: NSPanel?
    /// Live only while the status menu is open: a global mouse monitor (dismiss on any outside click,
    /// incl. other menu-bar icons) and a resign-active observer (dismiss on Cmd-Tab / focus loss).
    private var statusMenuMonitor: Any?
    private var statusMenuResignObserver: NSObjectProtocol?
    /// When the menu last closed — so the same click that dismissed it (via the monitor) doesn't get
    /// re-opened by the status-item action firing immediately after.
    private var statusMenuLastClosed: Date?
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
        guard let button = statusItem?.button, let iconWindow = button.window else { return }
        if statusMenuPanel != nil {               // already open → the click toggles it closed
            closeStatusMenu()
            return
        }
        // The click that dismissed the menu also fires the status-item action; don't re-open on it.
        if let closed = statusMenuLastClosed, Date().timeIntervalSince(closed) < 0.2 { return }

        let view = StatusMenuView(
            clipCount: store.matches(query: "").count,
            version: Self.appVersion,
            accessibilityTrusted: AccessibilityPermission.isTrusted,
            shortcutStore: shortcutStore,
            linkPreviewsOn: LinkMetadataProvider.isAutoFetchEnabled,
            runInBackground: runsInBackground,
            onShow: { [weak self] in self?.closeStatusMenu(); self?.showPanel() },
            onToggleLinkPreviews: { [weak self] in self?.toggleLinkPreviews() },
            onToggleBackground: { [weak self] in self?.toggleBackgroundMode() },
            onClearHistory: { [weak self] in self?.closeStatusMenu(); self?.clearUnpinned() },
            onCheckUpdates: { [weak self] in self?.closeStatusMenu(); self?.checkForUpdates(nil) },
            onClose: { [weak self] in self?.closeStatusMenu() },
            onGrantAccessibility: { [weak self] in self?.closeStatusMenu(); self?.openAccessibilitySettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        let hosting = NSHostingController(rootView: view)
        let size = hosting.view.fittingSize

        let panel = StatusMenuPanel(
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
        panel.hidesOnDeactivate = false           // we dismiss explicitly via the resign-active observer
        panel.animationBehavior = .utilityWindow

        // Drop straight down from the icon, centered on it, clamped fully on-screen.
        let iconFrame = iconWindow.frame
        var origin = NSPoint(x: iconFrame.midX - size.width / 2, y: iconFrame.minY - 4 - size.height)
        if let vis = (iconWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - size.width - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        statusMenuPanel = panel

        // Activate so the buttons are clickable and Esc (the view's onExitCommand) reaches a key window.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        statusMenuMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closeStatusMenu()
        }
        statusMenuResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeStatusMenu() }
        }
    }

    private func closeStatusMenu() {
        if let monitor = statusMenuMonitor {
            NSEvent.removeMonitor(monitor)
            statusMenuMonitor = nil
        }
        if let observer = statusMenuResignObserver {
            NotificationCenter.default.removeObserver(observer)
            statusMenuResignObserver = nil
        }
        statusMenuPanel?.orderOut(nil)
        statusMenuPanel = nil
        statusMenuLastClosed = Date()
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

/// A borderless panel that can become key — so the status menu's Esc and its buttons work — used to
/// present the status menu without NSPopover's arrow (a clean drop-down straight under the icon).
private final class StatusMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
