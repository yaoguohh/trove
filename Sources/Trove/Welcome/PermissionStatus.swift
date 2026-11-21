import Combine
import Foundation

/// Live state of the two permissions for the welcome window. Neither has a change notification, so
/// it re-reads them once a second while the window is open.
@MainActor
final class PermissionStatus: ObservableObject {
    @Published private(set) var accessibilityGranted = AccessibilityPermission.isTrusted
    @Published private(set) var clipboardAllowed = ClipboardAccessPermission.isAllowed
    private var timer: Timer?

    func startWatching() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let granted = AccessibilityPermission.isTrusted
        if granted != accessibilityGranted { accessibilityGranted = granted }
        let allowed = ClipboardAccessPermission.isAllowed
        if allowed != clipboardAllowed { clipboardAllowed = allowed }
    }
}
