import Foundation

/// Single source of truth for ClipDeck's on-disk locations, replacing the
/// `FileManager...urls(...).first!` force-unwrap that was duplicated across files.
enum AppPaths {
    static var applicationSupport: URL {
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("ClipDeck", isDirectory: true)
        }
        // ~/Library/Application Support is effectively guaranteed on macOS, but we
        // degrade to an explicit path instead of crashing on a sandbox edge case.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClipDeck", isDirectory: true)
    }

    static func applicationSupportSubdirectory(_ name: String) -> URL {
        applicationSupport.appendingPathComponent(name, isDirectory: true)
    }

    static var historyFileURL: URL {
        applicationSupport.appendingPathComponent("history.json")
    }

    static var imageDirectoryURL: URL {
        applicationSupportSubdirectory("images")
    }
}
