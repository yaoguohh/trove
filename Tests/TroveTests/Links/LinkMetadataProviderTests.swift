import Foundation
import Testing
@testable import Trove

struct LinkMetadataMigrationTests {
    @Test func legacyCacheWithoutPortStillDecodes() throws {
        let data = Data(#"{"url":"https://example.com","title":"Example","host":"example.com","iconFileName":null}"#.utf8)
        let metadata = try JSONDecoder().decode(LinkMetadata.self, from: data)
        #expect(metadata.host == "example.com")
        #expect(metadata.port == nil)
    }
}

struct LinkMetadataNegativeCacheTests {
    private func empty(fetchedAt: Date?) -> LinkMetadata {
        LinkMetadata(title: nil, host: "example.com", port: nil, iconFileName: nil, fetchedAt: fetchedAt)
    }

    @Test func emptyRecordExpiresAfterTheTTL() {
        let now = Date()
        #expect(LinkMetadataProvider.isStale(empty(fetchedAt: now.addingTimeInterval(-2 * 86_400)), now: now))
        #expect(!LinkMetadataProvider.isStale(empty(fetchedAt: now.addingTimeInterval(-60)), now: now))
    }

    @Test func legacyEmptyRecordWithoutTimestampCountsAsStale() {
        #expect(LinkMetadataProvider.isStale(empty(fetchedAt: nil), now: Date()))
    }

    @Test func recordsWithContentNeverExpire() {
        let old = Date(timeIntervalSinceNow: -365 * 86_400)
        var titled = empty(fetchedAt: old)
        titled.title = "Example"
        #expect(!LinkMetadataProvider.isStale(titled, now: Date()))
        var iconOnly = empty(fetchedAt: nil)
        iconOnly.iconFileName = "x-icon.png"
        #expect(!LinkMetadataProvider.isStale(iconOnly, now: Date()))
    }
}

struct LinkMetadataCachePruneTests {
    private func touch(_ directory: URL, _ name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent(name))
    }

    @Test func keyIsReadBackFromBothFileShapes() {
        #expect(LinkMetadataProvider.cacheKey(ofFileNamed: "a1b2.json") == "a1b2")
        #expect(LinkMetadataProvider.cacheKey(ofFileNamed: "a1b2-icon.png") == "a1b2")
    }

    @Test func queryAndFragmentDoNotChangeTheKey() {
        // The request drops query and fragment, so the cache key must too.
        #expect(LinkMetadataProvider.cacheKey(forRawURL: "https://example.com/a?token=1#x")
            == LinkMetadataProvider.cacheKey(forRawURL: "https://example.com/a"))
        #expect(LinkMetadataProvider.cacheKey(forRawURL: "not a link") == nil)
    }

    @Test func removesRecordsOfLinksNoLongerInHistory() throws {
        let directory = makeTempDirectory()
        let kept = try #require(LinkMetadataProvider.cacheKey(forRawURL: "https://example.com/kept"))
        let gone = try #require(LinkMetadataProvider.cacheKey(forRawURL: "https://example.com/gone"))
        for name in ["\(kept).json", "\(kept)-icon.png", "\(gone).json", "\(gone)-icon.ico"] {
            try touch(directory, name)
        }

        LinkMetadataProvider.pruneCache(
            keepingLinksIn: ["https://example.com/kept"],
            directory: directory,
            legacyDirectory: makeTempDirectory()
        )

        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(left == ["\(kept)-icon.png", "\(kept).json"].sorted())
    }

    @Test func movesTheLegacyCacheOnce() throws {
        let root = makeTempDirectory()
        let legacy = root.appendingPathComponent("legacy", isDirectory: true)
        let directory = root.appendingPathComponent("caches/link-metadata", isDirectory: true)
        let key = try #require(LinkMetadataProvider.cacheKey(forRawURL: "https://example.com/"))
        try touch(legacy, "\(key).json")

        LinkMetadataProvider.pruneCache(keepingLinksIn: ["https://example.com/"], directory: directory, legacyDirectory: legacy)

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(key).json").path))
    }
}
