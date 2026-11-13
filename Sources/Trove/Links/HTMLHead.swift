import Foundation

/// The little HTML a link card needs, read from a page's `<head>`: its title and icon links. Pure
/// string work with no WebKit, so it runs off the main thread.
enum HTMLHead {
    /// The page title (`<title>`, else `og:title`), entity-decoded.
    static func title(in html: String) -> String? {
        let raw = firstMatch(in: html, pattern: #"<title[^>]*>(.*?)</title>"#)
            ?? metaContent(in: html, property: "og:title")
        return raw.map(decodeEntities)
    }

    static func iconURLs(in html: String, baseURL: URL) -> [URL] {
        let pattern = #"<link\s+[^>]*rel=["'][^"']*(?:apple-touch-icon|shortcut icon|icon)[^"']*["'][^>]*>"#
        let linkTags = matches(in: html, pattern: pattern)
        return linkTags.compactMap { tag in
            guard let href = attribute("href", in: tag) else { return nil }
            return URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
    }

    /// Bytes read between checks for `</head`, so a fetch can stop once the head is complete.
    static let checkStride = 16 * 1024
    private static let endMarker = Data("</head".utf8)

    /// Case-insensitive `</head` search over the most recent `window` bytes (plus the marker length,
    /// so a marker straddling two strides is still found).
    static func containsEnd(_ data: Data, lookingBackFrom window: Int) -> Bool {
        let start = max(0, data.count - window - endMarker.count)
        let tail = data[start...]
        // ASCII-lowercase the window: `</HEAD>` is legal HTML.
        let lowered = Data(tail.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 0x20 : $0 })
        return lowered.range(of: endMarker) != nil
    }

    private static func metaContent(in html: String, property: String) -> String? {
        let pattern = #"<meta\s+[^>]*(?:property|name)=["']\#(property)["'][^>]*>"#
        return matches(in: html, pattern: pattern)
            .compactMap { attribute("content", in: $0) }
            .first
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
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

    private static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
        }
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        firstMatch(in: tag, pattern: #"\#(name)\s*=\s*["']([^"']+)["']"#)
    }

    /// Pure HTML entity decoder. NSAttributedString(.html) can't be used here: it is WebKit-backed and
    /// main-thread-only, and this runs on a background executor (the enclosing fetch is `nonisolated async`).
    static func decodeEntities(_ value: String) -> String {
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

    private static func decodeEntity(_ body: String) -> String? {
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

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "copy": "©", "reg": "®", "trade": "™",
        "hellip": "…", "mdash": "—", "ndash": "–", "middot": "·",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "laquo": "«", "raquo": "»", "deg": "°", "euro": "€", "pound": "£", "cent": "¢", "yen": "¥"
    ]
}
