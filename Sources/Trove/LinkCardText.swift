import Foundation

/// The three strings a link card shows, derived purely (no network, no I/O) from the raw copied URL
/// plus any already-fetched `LinkMetadata`. Promoting the URL PATH — the part that actually differs
/// between links to the same host — is what keeps two same-host clips from collapsing to identical
/// "github.com / github.com" cards (the bug this type fixes). Kept SwiftUI-free so the parsing and
/// formatting rules are exhaustively unit-testable (mirrors `RichPreviewRenderer`).
struct LinkCardText: Equatable {
    /// Hero line: the fetched page title, else a smart path-tail, else the host (root URLs).
    let primary: String
    /// The always-on monospaced route line (full path + non-tracking query + fragment). `nil` only
    /// for a true root URL or unparseable input — so it never shows an empty `/`.
    let route: String?
    /// Footer breadcrumb: the host, lowercased, `www.`-stripped, may carry `:port`. `""` if unparseable.
    let host: String
    /// Drives the view's line-limit split: when a real title occupies the hero the route gets one line,
    /// otherwise it gets two (there's no title competing for the card's height).
    let primaryIsTitle: Bool

    /// Path segments that read as a label on their own (so a trailing one is a poor hero) — for these
    /// the query usually carries the real discriminator (`/watch?v=…`, `/item?id=…`, `/search?q=…`).
    private static let genericSegments: Set<String> = [
        "watch", "item", "view", "p", "index", "page", "post",
        "status", "s", "search", "results", "embed", "edit",
    ]

    /// Query keys that tend to hold the discriminating value, in priority order.
    private static let discriminatorKeys = ["v", "id", "q", "query", "p", "list", "t"]

    /// Query keys that are tracking/attribution noise, never a discriminator.
    private static let trackingKeys: Set<String> = [
        "ref", "ref_src", "ref_url", "fbclid", "gclid", "igshid", "si",
        "mc_cid", "mc_eid", "source", "spm", "scid", "cmpid",
    ]

    static func make(rawURL: String, metadata: LinkMetadata?) -> LinkCardText {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // Inputs with stray spaces/control chars don't parse; show the raw text (capped) rather than
        // fabricate a host out of garbage.
        guard let comps = URLComponents(string: trimmed) else {
            return LinkCardText(
                primary: trimmed.isEmpty ? String(localized: "Link") : String(trimmed.prefix(120)),
                route: nil,
                host: "",
                primaryIsTitle: false
            )
        }

        let host = resolvedHost(comps: comps, metadata: metadata)
        // Segment + render from the PERCENT-ENCODED path so an encoded slash (%2F) stays inside one
        // segment and never collides with a real separator. `path` would decode %2F → "/".
        let encPath = comps.percentEncodedPath
        let segments = encPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { readableDecode(String($0)) }
        let route = resolvedRoute(comps: comps, encPath: encPath)
        let (primary, primaryIsTitle) = resolvedPrimary(
            comps: comps, metadata: metadata, segments: segments, hasRoute: route != nil, host: host
        )
        return LinkCardText(primary: primary, route: route, host: host, primaryIsTitle: primaryIsTitle)
    }

    // MARK: - Host

    private static func resolvedHost(comps: URLComponents, metadata: LinkMetadata?) -> String {
        // `comps.host` is the DECODED IDN host (münchen.de, not punycode) and excludes userinfo, so
        // credentials are never shown. Prefer the fetched host/port when present because they reflect
        // redirects; never attach the source URL's port to a different, redirected metadata host.
        let sourceHost = normalizedHost(comps.host ?? "")
        if let metadataHost = metadata?.host, !metadataHost.isEmpty {
            let host = normalizedHost(metadataHost)
            // Old cache entries predate LinkMetadata.port. Reuse the source port only when the host
            // is unchanged; a different host means a redirect and its unknown port must not be guessed.
            let port = metadata?.port ?? (host == sourceHost ? comps.port : nil)
            return append(port: port, to: host)
        }
        return append(port: comps.port, to: sourceHost)
    }

    private static func normalizedHost(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    private static func append(port: Int?, to host: String) -> String {
        guard let port, !host.isEmpty else { return host }
        return "\(host):\(port)"
    }

    // MARK: - Route line

    private static func resolvedRoute(comps: URLComponents, encPath: String) -> String? {
        var route = readableDecode(encPath)
        if route.count > 1, route.hasSuffix("/") { route.removeLast() }

        // Query values can distinguish otherwise-identical deep links just as much as paths do.
        // Keep every non-tracking item on every path, preserving its percent-encoded identity.
        if let query = visibleQuery(comps) {
            route += "?\(readableDecode(query))"
        }
        // `percentEncodedPath` drops the fragment, so read it separately (SPA routes live here).
        if let fragment = comps.percentEncodedFragment, !fragment.isEmpty {
            route += "#\(readableDecode(fragment))"
        }

        return (route.isEmpty || route == "/") ? nil : route
    }

    private static func visibleQuery(_ comps: URLComponents) -> String? {
        guard let items = comps.percentEncodedQueryItems else { return nil }
        let visible = items.filter { !isTracking(readableDecode($0.name)) }
        guard !visible.isEmpty else { return nil }

        var rendered = URLComponents()
        rendered.percentEncodedQueryItems = visible
        return rendered.percentEncodedQuery
    }

    // MARK: - Hero

    private static func resolvedPrimary(
        comps: URLComponents,
        metadata: LinkMetadata?,
        segments: [String],
        hasRoute: Bool,
        host: String
    ) -> (String, Bool) {
        if let title = metadata?.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (title, true)
        }

        var primary = ""
        if let last = segments.last {
            if genericSegments.contains(last.lowercased()), let value = discriminator(comps) {
                primary = String(value.prefix(40))
            } else if segments.count >= 2 {
                // Keep the parent segment (e.g. an org) so forks/siblings stay distinct; the view
                // tail-truncates if it's wide. Never silently drop to the last segment alone.
                primary = "\(segments[segments.count - 2])/\(last)"
            } else {
                primary = last
            }
        } else if let fragmentTail = fragmentTail(comps) {
            // No path segments, but an SPA fragment route carries the identity (/#/dashboard).
            primary = fragmentTail
        } else if let value = discriminator(comps) {
            // …or an only-query URL (/?q=apple) does.
            primary = String(value.prefix(40))
        } else {
            primary = host
        }

        if primary.isEmpty { primary = host.isEmpty ? String(localized: "Link") : host }
        return (primary, false)
    }

    /// The most likely discriminating query value: a known key first (skipping tracking params), else
    /// the first non-tracking, non-empty value. `queryItems` values arrive already percent-decoded.
    private static func discriminator(_ comps: URLComponents) -> String? {
        guard let items = comps.queryItems else { return nil }
        for key in discriminatorKeys {
            if let value = items.first(where: { $0.name.lowercased() == key && !($0.value ?? "").isEmpty })?.value {
                return value
            }
        }
        for item in items where !isTracking(item.name) {
            if let value = item.value, !value.isEmpty { return value }
        }
        return nil
    }

    private static func isTracking(_ key: String) -> Bool {
        let lower = key.lowercased()
        return lower.hasPrefix("utm_") || trackingKeys.contains(lower)
    }

    /// The last meaningful segment of a fragment route (`#/a/b` → "b"), for client-routed SPAs.
    private static func fragmentTail(_ comps: URLComponents) -> String? {
        guard let fragment = comps.percentEncodedFragment, !fragment.isEmpty else { return nil }
        let parts = fragment.split(separator: "/", omittingEmptySubsequences: true).map { readableDecode(String($0)) }
        return parts.last
    }

    // MARK: - Decoding

    /// Percent-decode for readability while preserving encoded slash (`%2F`) and percent (`%25`).
    /// Decoding slash would collapse one segment into a real multi-segment path; decoding percent could
    /// turn `%252F` into the same display as `%2F`. Decode only the chunks between those reserved bytes,
    /// avoiding a sentinel that could itself be valid URL content.
    private static func readableDecode(_ encoded: String) -> String {
        guard encoded.contains("%") else { return encoded }

        var result = ""
        var chunkStart = encoded.startIndex
        var cursor = encoded.startIndex
        while cursor < encoded.endIndex {
            guard encoded[cursor] == "%" else {
                cursor = encoded.index(after: cursor)
                continue
            }
            let first = encoded.index(after: cursor)
            guard first < encoded.endIndex else { break }
            let second = encoded.index(after: first)
            guard second < encoded.endIndex else { break }

            let hex = encoded[first...second].uppercased()
            guard hex == "2F" || hex == "25" else {
                cursor = encoded.index(after: cursor)
                continue
            }

            let chunk = String(encoded[chunkStart..<cursor])
            result += chunk.removingPercentEncoding ?? chunk
            result += "%\(hex)"
            cursor = encoded.index(after: second)
            chunkStart = cursor
        }

        let tail = String(encoded[chunkStart...])
        result += tail.removingPercentEncoding ?? tail
        return result
    }
}
