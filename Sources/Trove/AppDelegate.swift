import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var store = ClipboardStore(maxItems: settings.maxItems)
    private var monitor: ClipboardMonitor?
    private var clipPasteboard: ClipPasteboard?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var statusMenu: StatusMenuController?
    private var panelController: ClipboardPanelController?
    private var updaterController: UpdaterController?
    private var settingsObservers: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dark-only by design: the panel is a Dock/HUD-class floating surface, and every color in the
        // app is a single anthracite token (see Theme). Pinning the appearance app-wide keeps the
        // inspect window, menus and alerts on the same side.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let clipboardMonitor = ClipboardMonitor(store: store)
        monitor = clipboardMonitor
        clipboardMonitor.start()
        Log.clipboard.notice("clipboard access behavior: \(ClipboardAccessPermission.logDescription, privacy: .public)")
        let pasteboard = ClipPasteboard(store: store, monitor: clipboardMonitor)
        clipPasteboard = pasteboard

        panelController = ClipboardPanelController(store: store, pasteboard: pasteboard)
        let hotKeys = HotKeyManager { [weak self] in
            self?.togglePanel()
        }
        hotKeyManager = hotKeys
        // Sparkle auto-updates: starts scheduled background checks (release builds only — the
        // updater runtime lives in the packaged .app's embedded Sparkle.framework).
        let updater = UpdaterController()
        updaterController = updater
        statusMenu = StatusMenuController(
            store: store,
            settings: settings,
            updater: updater,
            hotKeys: hotKeys,
            showPanel: { [weak self] in self?.showPanel() }
        )

        // `@Published` emits the current value on subscribe, so these also apply the launch state.
        settings.$shortcut
            .sink { [weak hotKeys] in hotKeys?.register(shortcut: $0) }
            .store(in: &settingsObservers)
        settings.$runInBackground
            .sink { NSApp.setActivationPolicy($0 ? .accessory : .regular) }
            .store(in: &settingsObservers)

        configureMenuBar()

        // Image clips stored before thumbnails existed get theirs generated once, off-main, after the
        // launch path has settled. TODO(v1.5): remove with `ClipboardStore.backfillThumbnails`.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.store.backfillThumbnails()
        }
        let linkTexts = store.items.filter { $0.kind == .link }.map(\.text)
        Task.detached(priority: .utility) {
            LinkMetadataProvider.pruneCache(keepingLinksIn: linkTexts)
        }
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
        // `item.menu` directly would suppress the action entirely, so the menu is presented on demand.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    private func togglePanel() {
        if panelController?.isVisible == true {
            panelController?.hide(animated: true)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        clipPasteboard?.rememberTarget()
        panelController?.show()
    }

    @objc private func statusItemClicked() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let button = statusItem?.button {
            statusMenu?.toggle(under: button)
        } else {
            togglePanel()
        }
    }
}
