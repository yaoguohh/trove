import Foundation

/// What a link card shows besides the URL: the page title, the final host/port, and a cached favicon.
struct LinkMetadata: Codable, Equatable {
    var title: String?
    var host: String
    /// Final response port, when explicit. Optional so metadata cached by older releases still decodes.
    var port: Int? = nil
    var iconFileName: String?
    /// When this record was produced. Lets a failed lookup (no title, no icon) expire and be retried
    /// instead of being cached forever, so a link copied while offline still gets its title later.
    /// Optional so records cached by older releases still decode (they count as expired once).
    var fetchedAt: Date? = nil

    var iconFileURL: URL? {
        guard let iconFileName else { return nil }
        return LinkMetadataProvider.cacheDirectoryURL.appendingPathComponent(iconFileName)
    }
}
