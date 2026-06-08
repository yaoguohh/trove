import Foundation

/// What the inspect window should render a clip as. A PURE display classification over verbatim text
/// — never fed back into copy/paste/drag. Kept free of SwiftUI so the detection/formatting rules are
/// exhaustively unit-testable (mirrors the PanelKeyboard pure-decision layer).
enum RichPreviewContent: Equatable {
    case url(String)       // a single bare URL (the trimmed string)
    case json(String)      // the pretty-printed JSON
    case plain             // everything else — render as bounded plain text
}

/// What the "expand" affordance (the peek bubble's ↗ button and the card's right-click Preview) should
/// do for a clip. A single bare URL opens in the default browser — rendering a web page inside a native
/// card just duplicates the browser — while everything else opens the in-app inspect window.
enum ExpandAction: Equatable {
    case openURL(URL)
    case inspectWindow
}

enum RichPreviewRenderer {
    /// Decide what expanding a clip should do (pure, so the routing is unit-testable apart from the
    /// AppKit side effects). Only a single openable URL routes to the browser; multi-line `.link`-kind
    /// clips, JSON, and plain text all fall back to the inspect window.
    static func expandAction(for text: String, kind: ClipboardKind) -> ExpandAction {
        if case .url(let link) = detect(text, kind: kind), let url = URL(string: link) {
            return .openURL(url)
        }
        return .inspectWindow
    }

    /// A clip is a single link only if it's one bare URL — no interior whitespace/newline (so a
    /// paragraph that merely starts with a link is NOT treated as a link card). Bounded to a sane
    /// length so this stays O(cap) even if handed something huge.
    static func isSingleURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else { return false }
        guard !trimmed.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return false }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
        return URL(string: trimmed) != nil
    }

    /// Pretty-print valid JSON natively (zero dependencies). Gated three ways so it never does heavy
    /// work on non-JSON or oversized input: first char must be `{`/`[`, the UTF-8 size must be within
    /// `maxBytes`, and it must actually parse. Returns `nil` (→ render as plain) otherwise.
    static func prettyJSON(_ text: String, maxBytes: Int = 256 * 1024) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return nil }
        let data = Data(trimmed.utf8)
        guard data.count <= maxBytes else { return nil }
        guard
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let string = String(data: pretty, encoding: .utf8)
        else { return nil }
        return string
    }

    /// Classify a clip for the inspect window. Detection runs on the BOUNDED inline `text`
    /// (≤ inlineTextCap) so it's cheap; a JSON clip larger than that keeps its sidecar full text but
    /// renders as plain (its truncated inline prefix won't parse) — an accepted limitation.
    static func detect(_ text: String, kind: ClipboardKind) -> RichPreviewContent {
        if kind == .link, isSingleURL(text) {
            return .url(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let pretty = prettyJSON(text) {
            return .json(pretty)
        }
        return .plain
    }
}
