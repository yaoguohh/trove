import Foundation

/// Single source of truth for Trove's on-disk locations, replacing the
/// `FileManager...urls(...).first!` force-unwrap that was duplicated across files.
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

    static var historyFileURL: URL {
        applicationSupport.appendingPathComponent("history.json")
    }

    static var imageDirectoryURL: URL {
        applicationSupportSubdirectory("images")
    }

    /// Sidecar `.txt` files holding the full text of clips too large to keep inline in `history.json`
    /// (mirrors the `images/` PNG sidecar pattern, with the same orphan-reconcile guarantee).
    static var textDirectoryURL: URL {
        applicationSupportSubdirectory("texts")
    }
}
