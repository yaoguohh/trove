import AppKit
import Sparkle

/// Wraps Sparkle's standard updater so the menu bar can offer "Check for Updates…" and run
/// scheduled background checks. Sparkle verifies updates with its OWN EdDSA key (`SUPublicEDKey`
/// in Info.plist + `sparkle:edSignature` in the appcast), independent of Apple notarization — so
/// this works on ClipDeck's free, ad-hoc-signed distribution path. See memory:
/// distribution-and-update-strategy.
///
/// Note: the update runtime (Sparkle.framework's embedded Autoupdate.app / XPC services) only
/// exists in the packaged `.app`. In a raw `swift run` dev build there's no SUFeedURL/SUPublicEDKey
/// in the bundle, so `canCheckForUpdates` is false and "Check for Updates" reports it can't check —
/// that's expected; updates are a release-build feature.
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController

    init() {
        // startingUpdater: true → begins scheduled background checks driven by Info.plist
        // (SUEnableAutomaticChecks / SUScheduledCheckInterval). The standard flow needs no
        // delegates. Missing feed config is handled gracefully by Sparkle (logged, no crash).
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    /// True once Sparkle is configured (feed URL + key present) and not mid-check — used to
    /// enable/disable the menu item.
    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }
}
