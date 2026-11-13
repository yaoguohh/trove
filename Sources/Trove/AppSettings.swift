import Foundation

/// Every user preference, persisted in `UserDefaults` under the keys below. Views bind to the
/// published properties directly, so a setting has exactly one in-memory value.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let shortcut = "Trove.showPanelShortcut"
        static let linkPreviews = "Trove.linkMetadataAutoFetch"
        static let runInBackground = "Trove.runInBackground"
        /// No UI: `defaults write io.github.yaoguohh.trove Trove.maxItems 1000`.
        static let maxItems = "Trove.maxItems"
    }

    static let defaultMaxItems = 500
    static let maxItemsRange = 50...5000

    /// The global hotkey that summons the panel.
    @Published var shortcut: HotKeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) {
                defaults.set(data, forKey: Key.shortcut)
            }
        }
    }

    /// Whether link cards may fetch the page title and favicon (see `LinkMetadataProvider`).
    @Published var linkPreviews: Bool {
        didSet { defaults.set(linkPreviews, forKey: Key.linkPreviews) }
    }

    /// Menu-bar only (no Dock icon). On by default, like other menu-bar utilities.
    @Published var runInBackground: Bool {
        didSet { defaults.set(runInBackground, forKey: Key.runInBackground) }
    }

    /// History cap, read once at launch.
    let maxItems: Int

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shortcut = defaults.data(forKey: Key.shortcut)
            .flatMap { try? JSONDecoder().decode(HotKeyShortcut.self, from: $0) }
            ?? .defaultShowPanel
        linkPreviews = defaults.bool(forKey: Key.linkPreviews)
        runInBackground = defaults.object(forKey: Key.runInBackground) as? Bool ?? true
        let configured = defaults.integer(forKey: Key.maxItems)
        maxItems = configured == 0
            ? Self.defaultMaxItems
            : min(Self.maxItemsRange.upperBound, max(Self.maxItemsRange.lowerBound, configured))
    }
}
