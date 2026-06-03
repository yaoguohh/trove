import Darwin
import Foundation
import ImageIO

struct LinkMetadata: Codable, Equatable {
    var url: String
    var title: String?
    var host: String
    var iconFileName: String?

    var iconFileURL: URL? {
        guard let iconFileName else { return nil }
        return LinkMetadataProvider.cacheDirectoryURL.appendingPathComponent(iconFileName)
    }
}

@MainActor
final class LinkMetadataProvider {
    static let shared = LinkMetadataProvider()

    private nonisolated static let maxHTMLBytes = 2_000_000
    private nonisolated static let maxIconBytes = 1_000_000
    nonisolated static let autoFetchDefaultsKey = "ClipDeck.linkMetadataAutoFetch"

    /// Whether link cards may reach out to the network to fetch title/favicon.
    /// Defaults to enabled, but users can turn it off to avoid leaking which URLs
    /// they copy to third-party hosts.
    nonisolated static var isAutoFetchEnabled: Bool {
        get {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: autoFetchDefaultsKey) == nil { return true }
            return defaults.bool(forKey: autoFetchDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: autoFetchDefaultsKey) }
    }

    private var memoryCache: [String: LinkMetadata] = [:]
    private var memoryCacheOrder: [String] = []
    private let memoryCacheLimit = 200
    private var inFlight: [String: Task<LinkMetadata?, Never>] = [:]
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    nonisolated static var cacheDirectoryURL: URL {
        AppPaths.applicationSupportSubdirectory("link-metadata")
    }

    func metadata(for rawURL: String) async -> LinkMetadata? {
        guard let url = normalizedURL(from: rawURL) else { return nil }
        let requestURL = Self.sanitizedRequestURL(url)
        let key = cacheKey(for: requestURL)
        if let cached = memoryCache[key] {
            return cached
        }
        if let cached = readCachedMetadata(for: key) {
            cacheInMemory(key, cached)
            return cached
        }
        // Privacy: never hit the network unless the user has opted in.
        guard Self.isAutoFetchEnabled else {
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
            NSLog("ClipDeck failed to cache link metadata: \(error.localizedDescription)")
        }
    }

    private func normalizedURL(from rawURL: String) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "http" || url.scheme == "https" else {
            return nil
        }
        guard let host = url.host(), Self.isAllowedHost(host) else { return nil }
        return url
    }

    /// Drops query and fragment so we never forward copied tokens/secrets to the host.
    nonisolated static func sanitizedRequestURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    private func cacheKey(for url: URL) -> String {
        Self.stableHash(url.absoluteString)
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
        do {
            let (data, response) = try await fetch(from: url, accept: "text/html,application/xhtml+xml", maxBytes: maxHTMLBytes)
            guard let httpResponse = response as? HTTPURLResponse, 200..<400 ~= httpResponse.statusCode else {
                return fallbackMetadata(for: url)
            }

            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let baseURL = response.url ?? url
            let title = firstMatch(in: html, pattern: #"<title[^>]*>(.*?)</title>"#)
                ?? metaContent(in: html, property: "og:title")
            let iconURL = iconCandidates(in: html, baseURL: baseURL).first ?? URL(string: "/favicon.ico", relativeTo: baseURL)?.absoluteURL
            let iconFileName = await fetchIcon(from: iconURL, key: key)

            return LinkMetadata(
                url: url.absoluteString,
                title: title.map(decodeHTMLEntities),
                host: baseURL.host() ?? url.host() ?? url.absoluteString,
                iconFileName: iconFileName
            )
        } catch {
            return fallbackMetadata(for: url)
        }
    }

    private nonisolated static func fallbackMetadata(for url: URL) -> LinkMetadata {
        LinkMetadata(url: url.absoluteString, title: nil, host: url.host() ?? url.absoluteString, iconFileName: nil)
    }

    private nonisolated static func iconCandidates(in html: String, baseURL: URL) -> [URL] {
        let pattern = #"<link\s+[^>]*rel=["'][^"']*(?:apple-touch-icon|shortcut icon|icon)[^"']*["'][^>]*>"#
        let linkTags = matches(in: html, pattern: pattern)
        return linkTags.compactMap { tag in
            guard let href = attribute("href", in: tag) else { return nil }
            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
    }

    private nonisolated static func fetchIcon(from url: URL?, key: String) async -> String? {
        guard let url else { return nil }
        do {
            guard let host = url.host(), isAllowedHost(host) else { return nil }
            let (data, response) = try await fetch(from: url, accept: "image/*,*/*;q=0.5", maxBytes: maxIconBytes)
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
    /// chunked endpoint cannot exhaust memory. Redirects are validated per-hop by
    /// `SSRFGuardSessionDelegate`, and the host is re-checked against resolved IPs.
    private nonisolated static func fetch(from url: URL, accept: String, maxBytes: Int) async throws -> (Data, URLResponse) {
        guard let host = url.host(), isAllowedHost(host), hostResolvesToAllowedAddress(host) else {
            throw URLError(.badServerResponse)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = SSRFGuardSessionDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, timeoutInterval: 7)
        request.setValue("ClipDeck/0.1 LinkMetadata", forHTTPHeaderField: "User-Agent")
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
        for try await byte in bytes {
            data.append(byte)
            if data.count > maxBytes {
                bytes.task.cancel()
                throw URLError(.dataLengthExceedsMaximum)
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

    // MARK: - SSRF protection

    /// String-layer host allow check. Rejects loopback/`.local` names and any
    /// private/reserved IP literal (dotted, integer, or hex IPv4, and IPv6).
    /// Real DNS names pass here and are guarded again by `hostResolvesToAllowedAddress`.
    nonisolated static func isAllowedHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased().trimmingCharacters(in: .whitespaces)
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") {
            return false
        }
        if let canonical = canonicalLiteralIP(host) {
            return !isPrivateOrReserved(ip: canonical)
        }
        return true
    }

    /// Resolves a hostname and blocks if ANY resolved address is private/reserved.
    /// Returns true when resolution yields no addresses (the connection will then
    /// simply fail without reaching anything internal).
    nonisolated static func hostResolvesToAllowedAddress(_ host: String) -> Bool {
        let addresses = resolvedAddresses(for: host)
        guard !addresses.isEmpty else { return true }
        return addresses.allSatisfy { !isPrivateOrReserved(ip: $0) }
    }

    nonisolated static func resolvedAddresses(for host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }

        var addresses: [String] = []
        var pointer = result
        while let current = pointer {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                addresses.append(String(decoding: bytes, as: UTF8.self))
            }
            pointer = current.pointee.ai_next
        }
        return addresses
    }

    /// Classifies a numeric IP string (IPv4 or IPv6) as private/reserved/loopback.
    nonisolated static func isPrivateOrReserved(ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let octets = parts.compactMap { Int($0) }
            if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
                return isPrivateIPv4(octets)
            }
        }
        return isPrivateOrReservedIPv6(ip)
    }

    nonisolated static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 0: return true                                   // 0.0.0.0/8 "this network"
        case 10: return true                                  // 10.0.0.0/8
        case 127: return true                                 // loopback
        case 100 where (64...127).contains(octets[1]): return true  // 100.64.0.0/10 CGNAT
        case 169 where octets[1] == 254: return true          // link-local
        case 172 where (16...31).contains(octets[1]): return true   // 172.16.0.0/12
        case 192 where octets[1] == 168: return true          // 192.168.0.0/16
        case 192 where octets[1] == 0 && octets[2] == 0: return true // 192.0.0.0/24
        case 198 where (18...19).contains(octets[1]): return true   // benchmarking
        case 224...255: return true                           // multicast + reserved
        default: return false
        }
    }

    nonisolated static func isPrivateOrReservedIPv6(_ raw: String) -> Bool {
        var value = raw.lowercased()
        if let zone = value.firstIndex(of: "%") { value = String(value[..<zone]) }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value == "::1" || value == "::" { return true }

        // IPv4-mapped / compatible (::ffff:a.b.c.d or ::a.b.c.d)
        if value.hasPrefix("::"), let lastColon = value.lastIndex(of: ":") {
            let tail = String(value[value.index(after: lastColon)...])
            if tail.contains(".") { return isPrivateOrReserved(ip: tail) }
        }

        let firstGroup = value.split(separator: ":").first.map(String.init) ?? value
        guard let leading = UInt16(firstGroup, radix: 16) else { return false }
        if (leading & 0xffc0) == 0xfe80 { return true }   // fe80::/10 link-local
        if (leading & 0xfe00) == 0xfc00 { return true }   // fc00::/7 unique local
        if (leading & 0xff00) == 0xff00 { return true }   // ff00::/8 multicast
        return false
    }

    /// Returns a canonical dotted-quad / IPv6 string if `host` is an IP literal in
    /// any common encoding (dotted, decimal integer, hex), otherwise nil (a name).
    nonisolated static func canonicalLiteralIP(_ host: String) -> String? {
        if host.contains(":") { return host } // IPv6 literal
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return host }
        if host.hasPrefix("0x") || host.hasPrefix("0X") {
            if let n = UInt32(host.dropFirst(2), radix: 16) { return dottedFromUInt32(n) }
            return nil
        }
        if let n = UInt32(host) { return dottedFromUInt32(n) }
        return nil
    }

    private nonisolated static func dottedFromUInt32(_ n: UInt32) -> String {
        "\((n >> 24) & 0xff).\((n >> 16) & 0xff).\((n >> 8) & 0xff).\(n & 0xff)"
    }

    // MARK: - HTML parsing helpers

    private nonisolated static func metaContent(in html: String, property: String) -> String? {
        let pattern = #"<meta\s+[^>]*(?:property|name)=["']\#(property)["'][^>]*>"#
        return matches(in: html, pattern: pattern)
            .compactMap { attribute("content", in: $0) }
            .first
    }

    private nonisolated static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private nonisolated static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch(in: tag, pattern: #"\#(name)\s*=\s*["']([^"']+)["']"#)
    }

    /// Pure HTML entity decoder. Replaces the previous NSAttributedString(.html)
    /// path, which is WebKit-backed and must run on the main thread — this ran on
    /// a background executor (the enclosing fetch is `nonisolated async`).
    nonisolated static func decodeHTMLEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = ""
        result.reserveCapacity(value.count)
        var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]
            if character == "&",
               let semicolon = value[index...].firstIndex(of: ";"),
               value.distance(from: index, to: semicolon) <= 10,
               let decoded = decodeEntity(String(value[value.index(after: index)..<semicolon])) {
                result.append(decoded)
                index = value.index(after: semicolon)
                continue
            }
            result.append(character)
            index = value.index(after: index)
        }
        return result
    }

    private nonisolated static func decodeEntity(_ body: String) -> String? {
        guard !body.isEmpty else { return nil }
        if body.hasPrefix("#") {
            let numeric = body.dropFirst()
            let scalarValue: UInt32?
            if let first = numeric.first, first == "x" || first == "X" {
                scalarValue = UInt32(numeric.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(numeric, radix: 10)
            }
            guard let value = scalarValue, let scalar = Unicode.Scalar(value) else { return nil }
            return String(scalar)
        }
        return namedEntities[body]
    }

    private nonisolated static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "«", "raquo": "»", "deg": "°", "euro": "€", "pound": "£", "cent": "¢", "yen": "¥"
    ]
}

/// Cancels HTTP redirects that would land on a disallowed (private/reserved) host,
/// closing the classic SSRF "public URL → 302 → internal address" bypass.
private final class SSRFGuardSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let scheme = request.url?.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = request.url?.host(),
              LinkMetadataProvider.isAllowedHost(host),
              LinkMetadataProvider.hostResolvesToAllowedAddress(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
