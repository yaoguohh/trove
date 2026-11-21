import AppKit
import PermissionFlow

/// Walks the user through granting Accessibility: PermissionFlow opens the pane in System Settings and
/// docks a small panel beside it with Trove's app card, which the user drags into the list. The
/// panel's copy follows Trove's own UI language, not the package's longer list of languages. While
/// the panel is up the guide watches for the grant (there is no notification for it), then closes
/// the panel and reports back.
@MainActor
final class PermissionGuide {
    /// Called once Accessibility is granted during a guide.
    var onGranted: (() -> Void)?

    private lazy var flow = PermissionFlow.makeController(configuration: .init(
        requiredAppURLs: [Bundle.main.bundleURL],
        promptForAccessibilityTrust: false,
        localeIdentifier: Self.localeIdentifier
    ))
    private var watch: Timer?
    /// A guide the user walked away from stops watching after this long.
    private static let watchLimit: TimeInterval = 15 * 60

    /// `sourceFrame` (screen coordinates) is where the app card flies from; nil skips that animation.
    func guideAccessibility(from sourceFrame: CGRect? = nil) {
        flow.authorize(pane: .accessibility, suggestedAppURLs: [Bundle.main.bundleURL], sourceFrameInScreen: sourceFrame)
        watch?.invalidate()
        let deadline = Date().addingTimeInterval(Self.watchLimit)
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(until: deadline) }
        }
    }

    private func check(until deadline: Date) {
        let granted = AccessibilityPermission.isTrusted
        guard granted || Date() > deadline else { return }
        watch?.invalidate()
        watch = nil
        guard granted else { return }
        flow.closePanel()
        onGranted?()
    }

    /// What System Settings calls the Accessibility list on this macOS (renamed in macOS 27), so the
    /// user can find it by its literal name.
    static var accessibilityName: String {
        PermissionFlowResources.localizedString(
            for: PermissionFlowResources.accessibilityName(),
            localeIdentifier: localeIdentifier
        )
    }

    private static var localeIdentifier: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }
}
