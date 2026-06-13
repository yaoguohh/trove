import AppKit

/// App-wide appearance choice. Applied via `NSApp.appearance`, the macOS-sanctioned
/// way to force light/dark for the whole app (panel, settings, and menus all follow).
enum AppAppearance: Int, CaseIterable, Identifiable {
    case system = 0
    case light = 1
    case dark = 2

    var id: Int { rawValue }

    /// Compact label for the inline status-menu segmented control (the only place appearance is
    /// chosen now). ".system" reads as "Auto" rather than "Follow System" so it fits a segment.
    var shortTitle: String {
        switch self {
        case .system: String(localized: "Auto")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    /// nil means "inherit the system appearance" (follow system).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
enum AppearanceManager {
    private static let defaultsKey = "Trove.appearance"

    static var current: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            apply()
        }
    }

    /// Applies the saved choice app-wide. Call at launch and whenever it changes.
    static func apply() {
        NSApp.appearance = current.nsAppearance
    }
}
