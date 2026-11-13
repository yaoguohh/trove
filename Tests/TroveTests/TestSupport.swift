import Foundation
@testable import Trove

/// A fresh, empty directory under the system temporary directory, unique per call.
func makeTempDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TroveTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A store rooted in its own temporary directory, and the URL of its history file. Every file the
/// store writes (sidecars, images) stays under that root.
@MainActor
func makeTempStore() -> (ClipStore, URL) {
    let files = ClipFiles(root: makeTempDirectory())
    return (ClipStore(files: files), files.historyFile)
}
