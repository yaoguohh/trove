import Foundation
import ImageIO

/// Fetches, caches and prunes link-card metadata (page title, favicon). Network access is opt-in
/// (`isFetchingEnabled`), every address is vetted by `LinkAddressGuard`, and only the `<head>` of a
/// page is read (`HTMLHead`).
@MainActor
final class LinkMetadataProvider {
    static let shared = LinkMetadataProvider()

    /// The title and icon links live in <head>; the reader also stops at </head>, so this is a ceiling
    /// for pathological pages, not the typical read.
    private nonisolated static let maxHTMLBytes = 512_000
    private nonisolated static let maxIconBytes = 1_000_000
    private nonisolated static let requestTimeout: TimeInterval = 7
    /// How long a lookup that produced nothing (no title, no icon) is believed before retrying.
    nonisolated static let negativeCacheTTL: TimeInterval = 24 * 60 * 60
    /// Cap on simultaneous page fetches, so a strip of uncached link cards doesn't fetch all at once.
    nonisolated static let maxConcurrentFetches = 4

    /// Whether link cards may reach out to the network to fetch title/favicon. Off until the user
    /// turns it on in the status menu: a fetch tells the link's host that the link was copied, and a
    /// one-time link whose token sits in the path (email verification, password reset) could be
    /// consumed just by showing its card. Cached records are still shown while it is off.
    static var isFetchingEnabled: Bool {
        AppSettings.shared.linkPreviews
    }

    private var memoryCache: [String: LinkMetadata] = [:]
    private var memoryCacheOrder: [String] = []
    private let memoryCacheLimit = 200
    private var inFlight: [String: Task<LinkMetadata?, Never>] = [:]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private nonisolated static let fetchGate = AsyncSemaphore(limit: maxConcurrentFetches)
    /// One session for every fetch: connection reuse, one delegate, no per-request setup/teardown.
    private nonisolated static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    nonisolated static var cacheDirectoryURL: URL {
        AppPaths.caches.appendingPathComponent("link-metadata", isDirectory: true)
    }

    /// Releases before 1.3 kept this cache under Application Support, where nothing ever pruned it.
    private nonisolated static var legacyCacheDirectoryURL: URL {
        AppPaths.applicationSupportSubdirectory("link-metadata")
    }

    /// Launch-time housekeeping, off the main actor: move a legacy cache into Caches once, then delete
    /// the records (and icons) of links no longer in history. `linkTexts` are the texts of the
    /// history's link clips — the same strings link cards look up.
    nonisolated static func pruneCache(
        keepingLinksIn linkTexts: [String],
        directory: URL = cacheDirectoryURL,
        legacyDirectory: URL = legacyCacheDirectoryURL
    ) {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: legacyDirectory.path) {
            if fileManager.fileExists(atPath: directory.path) {
                try? fileManager.removeItem(at: legacyDirectory)
            } else {
                try? fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.moveItem(at: legacyDirectory, to: directory)
            }
        }
        let live = Set(linkTexts.compactMap(cacheKey(forRawURL:)))
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !live.contains(cacheKey(ofFileNamed: file)) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    /// Cache files are `<key>.json` and `<key>-icon.<ext>`; the key is hex, so it ends at the first
    /// "." or "-".
    nonisolated static func cacheKey(ofFileNamed name: String) -> String {
        String(name.prefix { $0 != "." && $0 != "-" })
    }

    nonisolated static func cacheKey(forRawURL rawURL: String) -> String? {
        normalizedURL(from: rawURL).map { stableHash(sanitizedRequestURL($0).absoluteString) }
    }

    func metadata(for rawURL: String) async -> LinkMetadata? {
        guard let url = Self.normalizedURL(from: rawURL) else { return nil }
        let requestURL = Self.sanitizedRequestURL(url)
        let key = Self.stableHash(requestURL.absoluteString)
        // A cached record is reused unless it is an expired negative result (and fetching is allowed),
        // in which case it is refreshed below.
        let cached = memoryCache[key] ?? readCachedMetadata(for: key)
        if let cached {
            cacheInMemory(key, cached)
            if !(Self.isFetchingEnabled && Self.isStale(cached, now: Date())) {
                return cached
            }
        }
        // Privacy: never hit the network unless the user has turned link previews on.
        guard Self.isFetchingEnabled else {
            return Self.fallbackMetadata(for: requestURL)
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<LinkMetadata?, Never> {
            await Self.fetchMetadata(for: requestURL, key: key)
        }
        inFlight[key] = task
        let metadata = await task.value
        inFlight[key] = nil
        if let metadata {
            cacheInMemory(key, metadata)
            write(metadata, key: key)
        }
        return metadata
    }

    /// A record with nothing in it is retried once `negativeCacheTTL` has passed (legacy records
    /// without a timestamp count as expired). Records that carry a title or icon never expire.
    nonisolated static func isStale(_ metadata: LinkMetadata, now: Date) -> Bool {
        guard metadata.title == nil, metadata.iconFileName == nil else { return false }
        guard let fetchedAt = metadata.fetchedAt else { return true }
        return now.timeIntervalSince(fetchedAt) > negativeCacheTTL
    }

    /// Bounded in-memory hot cache: evicts the oldest entry past the limit. The disk
    /// cache remains the source of truth, so an eviction just costs one re-read.
    private func cacheInMemory(_ key: String, _ metadata: LinkMetadata) {
        if memoryCache[key] == nil {
            memoryCacheOrder.append(key)
            if memoryCacheOrder.count > memoryCacheLimit {
                let oldest = memoryCacheOrder.removeFirst()
                memoryCache[oldest] = nil
            }
        }
        memoryCache[key] = metadata
    }

    private func readCachedMetadata(for key: String) -> LinkMetadata? {
        let url = Self.cacheDirectoryURL.appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(LinkMetadata.self, from: data)
    }

    private func write(_ metadata: LinkMetadata, key: String) {
        do {
            try FileManager.default.createDirectory(at: Self.cacheDirectoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(metadata)
            try data.write(to: Self.cacheDirectoryURL.appendingPathComponent("\(key).json"), options: .atomic)
        } catch {
            Log.links.error("failed to cache link metadata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func normalizedURL(from rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        guard let host = url.host(), LinkAddressGuard.isAllowedHost(host) else { return nil }
        return url
    }

    /// Drops query and fragment so we never forward copied tokens/secrets to the host.
    nonisolated static func sanitizedRequestURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private nonisolated static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }

    private nonisolated static func fetchMetadata(for url: URL, key: String) async -> LinkMetadata? {
        // At most `maxConcurrentFetches` pages in flight across the whole app.
        await fetchGate.acquire()
        let metadata = await fetchMetadataUngated(for: url, key: key)
        await fetchGate.release()
        return metadata
    }

    private nonisolated static func fetchMetadataUngated(for url: URL, key: String) async -> LinkMetadata? {
        do {
            let (data, response) = try await fetch(from: url, accept: "text/html,application/xhtml+xml", maxBytes: maxHTMLBytes, stopAtHeadEnd: true)
            guard let httpResponse = response as? HTTPURLResponse, 200..<400 ~= httpResponse.statusCode else {
                return fallbackMetadata(for: url)
            }

            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let baseURL = response.url ?? url
            let iconURL = HTMLHead.iconURLs(in: html, baseURL: baseURL).first
                ?? URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL
            let iconFileName = await fetchIcon(from: iconURL, key: key)

            return LinkMetadata(
                title: HTMLHead.title(in: html),
                host: baseURL.host() ?? url.host() ?? url.absoluteString,
                port: baseURL.port,
                iconFileName: iconFileName,
                fetchedAt: Date()
            )
        } catch {
            return fallbackMetadata(for: url)
        }
    }

    /// What a link shows when nothing could be fetched: host + port only. Stamped so the negative
    /// result expires (`isStale`) instead of sticking forever.
    private nonisolated static func fallbackMetadata(for url: URL) -> LinkMetadata {
        LinkMetadata(
            title: nil,
            host: url.host() ?? url.absoluteString,
            port: url.port,
            iconFileName: nil,
            fetchedAt: Date()
        )
    }

    private nonisolated static func fetchIcon(from url: URL?, key: String) async -> String? {
        guard let url else { return nil }
        do {
            let (data, response) = try await fetch(from: url, accept: "image/*,*/*;q=0.5", maxBytes: maxIconBytes, stopAtHeadEnd: false)
            guard let httpResponse = response as? HTTPURLResponse, 200..<400 ~= httpResponse.statusCode else {
                return nil
            }
            // Validate the bytes decode as an image using thread-safe ImageIO (no AppKit on this background path).
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            let fileName = "\(key)-icon.\(iconFileExtension(for: response, url: url))"
            try FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            try data.write(to: cacheDirectoryURL.appendingPathComponent(fileName), options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    /// Streams the response and aborts once it exceeds `maxBytes`, so a hostile or
    /// chunked endpoint cannot exhaust memory. With `stopAtHeadEnd` the read also ends at `</head>`
    /// (everything the title/icon parser needs is above it), so a typical page costs tens of KB
    /// rather than its whole body. Redirects are validated per-hop by `RedirectGuard`,
    /// and the host is re-checked against resolved IPs — off the cooperative thread pool, since
    /// `getaddrinfo` blocks.
    private nonisolated static func fetch(from url: URL, accept: String, maxBytes: Int, stopAtHeadEnd: Bool) async throws -> (Data, URLResponse) {
        guard let host = url.host(), LinkAddressGuard.isAllowedHost(host),
              await LinkAddressGuard.hostResolvesToAllowedAddressAsync(host) else {
            throw URLError(.badServerResponse)
        }

        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.setValue("Trove/\(AppInfo.version) LinkMetadata", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)

        if let http = response as? HTTPURLResponse,
           http.expectedContentLength != NSURLSessionTransferSizeUnknown,
           http.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw URLError(.dataLengthExceedsMaximum)
        }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        var nextHeadCheck = HTMLHead.checkStride
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
            }
            if stopAtHeadEnd, data.count >= nextHeadCheck {
                nextHeadCheck += HTMLHead.checkStride
                if HTMLHead.containsEnd(data, lookingBackFrom: HTMLHead.checkStride) {
                    bytes.task.cancel()
                    break
                }
            }
        }
        return (data, response)
    }

    private nonisolated static func iconFileExtension(for response: URLResponse, url: URL) -> String {
        switch response.mimeType?.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/tiff":
            return "tiff"
        case "image/x-icon", "image/vnd.microsoft.icon":
            return "ico"
        default:
            let pathExtension = url.pathExtension.lowercased()
            return pathExtension.isEmpty ? "img" : pathExtension
        }
    }
}
