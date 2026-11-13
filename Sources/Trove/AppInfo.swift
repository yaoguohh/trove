import Foundation

/// Facts about the running build, read from the bundle once instead of re-spelled at each use site.
/// Under `swift run` / `swift test` there is no app bundle, so both fall back to development values.
enum AppInfo {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.yaoguohh.trove"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
