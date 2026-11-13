import Foundation

/// SSRF protection for link-metadata fetches: a copied link must never make Trove reach a loopback,
/// private, link-local or otherwise reserved address — not by literal, not through DNS, and not
/// through a redirect.
enum LinkAddressGuard {
    /// String-layer host allow check. Rejects loopback/`.local` names and any
    /// private/reserved IP literal (dotted, integer, or hex IPv4, and IPv6).
    /// Real DNS names pass here and are guarded again by `hostResolvesToAllowedAddress`.
    static func isAllowedHost(_ rawHost: String) -> Bool {
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
    static func hostResolvesToAllowedAddress(_ host: String) -> Bool {
        let addresses = resolvedAddresses(for: host)
        guard !addresses.isEmpty else { return true }
        return addresses.allSatisfy { !isPrivateOrReserved(ip: $0) }
    }

    static func resolvedAddresses(for host: String) -> [String] {
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
    static func isPrivateOrReserved(ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let octets = parts.compactMap { Int($0) }
            if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
                return isPrivateIPv4(octets)
            }
        }
        return isPrivateOrReservedIPv6(ip)
    }

    static func isPrivateIPv4(_ octets: [Int]) -> Bool {
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

    static func isPrivateOrReservedIPv6(_ raw: String) -> Bool {
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
    static func canonicalLiteralIP(_ host: String) -> String? {
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

    private static func dottedFromUInt32(_ n: UInt32) -> String {
        "\((n >> 24) & 0xff).\((n >> 16) & 0xff).\((n >> 8) & 0xff).\(n & 0xff)"
    }

    /// `hostResolvesToAllowedAddress` on a GCD queue: `getaddrinfo` is a blocking call and must not
    /// occupy one of the few cooperative-pool threads for the duration of a DNS lookup.
    static func hostResolvesToAllowedAddressAsync(_ host: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: hostResolvesToAllowedAddress(host))
            }
        }
    }
}

/// Cancels HTTP redirects that would land on a disallowed (private/reserved) host,
/// closing the classic SSRF "public URL → 302 → internal address" bypass.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
              LinkAddressGuard.isAllowedHost(host),
              LinkAddressGuard.hostResolvesToAllowedAddress(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
