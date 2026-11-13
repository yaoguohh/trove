import Foundation
import Testing
@testable import Trove

@MainActor
struct AppSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "TroveTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func defaultsForANewInstall() {
        let settings = AppSettings(defaults: freshDefaults())
        #expect(settings.linkPreviews == false)
        #expect(settings.runInBackground == true)
        #expect(settings.shortcut == .defaultShowPanel)
        #expect(settings.maxItems == AppSettings.defaultMaxItems)
    }

    @Test func maxItemsIsClampedToTheSupportedRange() {
        let low = freshDefaults()
        low.set(3, forKey: AppSettings.Key.maxItems)
        #expect(AppSettings(defaults: low).maxItems == AppSettings.maxItemsRange.lowerBound)

        let high = freshDefaults()
        high.set(1_000_000, forKey: AppSettings.Key.maxItems)
        #expect(AppSettings(defaults: high).maxItems == AppSettings.maxItemsRange.upperBound)
    }

    @Test func changesPersist() {
        let defaults = freshDefaults()
        let settings = AppSettings(defaults: defaults)
        let shortcut = HotKeyShortcut(keyCode: 9, carbonModifiers: 256)
        settings.shortcut = shortcut
        settings.linkPreviews = true
        settings.runInBackground = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.shortcut == shortcut)
        #expect(reloaded.linkPreviews == true)
        #expect(reloaded.runInBackground == false)
    }
}
