import Foundation

/// Single source of truth for Trove's on-disk locations.
enum AppPaths {
    static var applicationSupport: URL {
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("Trove", isDirectory: true)
        }
        // ~/Library/Application Support is effectively guaranteed on macOS, but we
        // degrade to an explicit path instead of crashing on a sandbox edge case.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Trove", isDirectory: true)
    }

    static func applicationSupportSubdirectory(_ name: String) -> URL {
        applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    /// Re-creatable data (link metadata). The system may purge it; nothing in it is user content.
    static var caches: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent("Trove", isDirectory: true)
    }
}
