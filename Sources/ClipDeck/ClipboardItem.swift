import CryptoKit
import Foundation

enum ClipboardKind: String, Codable, CaseIterable, Identifiable {
    case text
    case link
    case code
    case email
    case file
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: String(localized: "Text")
        case .link: String(localized: "Link")
        case .code: String(localized: "Code")
        case .email: String(localized: "Email")
        case .file: String(localized: "File")
        case .image: String(localized: "Image")
        }
    }

    var symbolName: String {
        switch self {
        case .text: "doc.text"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .email: "envelope"
        case .file: "doc"
        case .image: "photo"
        }
    }
}

struct Pinboard: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorName: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, colorName: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colorName = colorName
        self.createdAt = createdAt
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var sourceApp: String
    var sourceBundleIdentifier: String?
    var sourceAppPath: String?
    var imageFileName: String?
    var createdAt: Date
    var isPinned: Bool
    var kind: ClipboardKind
    var pinboardID: UUID?
    var title: String?
    var characterCount: Int
    /// Set when the clip's full text lives in a sidecar `.txt` (it exceeded `sidecarThreshold`); the
    /// inline `text` then holds only the first `inlineTextCap` characters. `nil` ⇒ `text` is the full
    /// verbatim content.
    var textFileName: String?
    /// SHA-256 of the verbatim full text, present only for sidecar-spilled clips. Lets `add` dedup a
    /// large re-copy in O(1) without reading every sidecar from disk.
    var fullTextHash: String?
    /// True only when the content was so large it hit `ultimateSidecarCeiling` and was hard-truncated
    /// (the rare case where paste loses the tail). Surfaced as a "Truncated" footer chip.
    var isTruncated: Bool
    /// The clip's true source length in characters (== `characterCount` except for ceiling-truncated
    /// clips, where `characterCount` is also the original length so the footer stays honest).
    var originalCharacterCount: Int

    /// Upper bound on the number of characters `preview` derives from the full text. A card only
    /// shows a handful of lines, so capping the SOURCE keeps `preview` (and everything downstream of
    /// it — card body, `displayTitle`, the drag image, the preview-window title) O(cap) instead of
    /// O(full text). The render hot path used to build a full newline-replaced copy of a multi-MB
    /// clip on every re-render.
    static let displayPreviewCap = 8_000

    var preview: String {
        // Take the prefix BEFORE the O(n) transforms so the work is bounded by `displayPreviewCap`,
        // not by the (possibly multi-MB) full text. `prefix(_:)` walks at most `displayPreviewCap`
        // characters; the copy then happens only on that already-bounded substring.
        text.prefix(Self.displayPreviewCap)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }
        return preview.isEmpty ? kind.title : preview
    }

    // MARK: - Storage cap (hybrid sidecar)

    /// Above this many characters, the full text spills to a sidecar `.txt` and only this many
    /// characters are kept inline in `history.json`. Bounds the in-memory array and the single
    /// prettyPrinted history document so 500 large clips can't blow up memory or the file.
    static let sidecarThreshold = 20_000
    /// The inline prefix kept for a spilled clip. Equal to `sidecarThreshold` (one boundary, no
    /// off-by-one): a clip is either fully inline (≤ threshold) or spilled with exactly this prefix.
    static let inlineTextCap = 20_000
    /// Ultimate ceiling: even the sidecar text is hard-truncated above this, so disk, the full-text
    /// cache and memory are all bounded even against a pathological multi-hundred-MB paste. 5M chars
    /// ≈ a 200-column × 5,000-row table — far beyond any human-copied document.
    static let ultimateSidecarCeiling = 5_000_000

    static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Resident decoded full-text bound (mirrors `ImageCache`). Path-keyed; each entry charged its
    /// UTF-8 byte size, so the cache self-bounds and a single oversized read can't pin more than the
    /// ceiling. `@MainActor` because `fullText` (its only user) is main-actor-isolated.
    @MainActor private static let fullTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    var textFileURL: URL? {
        textFileName.map { Self.textDirectoryURL.appendingPathComponent($0) }
    }

    var hasSidecarText: Bool { textFileName != nil }

    /// The FULL verbatim text, for the three fidelity consumers only (ClipboardMonitor.copy,
    /// PasteExecutor.paste, CardDragView.pasteboardWriter) and the inspect window. For sub-threshold
    /// clips this is just `text` (no IO). For spilled clips it does cached disk IO and degrades to the
    /// inline prefix if the sidecar is missing. MUST NOT be called from a SwiftUI body or per-keystroke
    /// search — those use `text`/`preview` (the bounded inline prefix).
    @MainActor
    var fullText: String {
        guard let url = textFileURL else { return text }
        let key = url.path as NSString
        if let cached = Self.fullTextCache.object(forKey: key) { return cached as String }
        guard let loaded = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("ClipDeck: full-text sidecar unreadable (\(url.lastPathComponent)); pasting the inline prefix only")
            // Memoize the fallback so a degraded clip doesn't re-stat + re-log on every paste/drag.
            Self.fullTextCache.setObject(text as NSString, forKey: key, cost: text.utf8.count)
            return text
        }
        Self.fullTextCache.setObject(loaded as NSString, forKey: key, cost: loaded.utf8.count)
        return loaded
    }

    init(
        id: UUID = UUID(),
        text: String,
        sourceApp: String,
        sourceBundleIdentifier: String? = nil,
        sourceAppPath: String? = nil,
        imageFileName: String? = nil,
        createdAt: Date = Date(),
        isPinned: Bool = false,
        kind: ClipboardKind = .text,
        pinboardID: UUID? = nil,
        title: String? = nil
    ) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceAppPath = sourceAppPath
        self.imageFileName = imageFileName
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.kind = kind
        self.pinboardID = pinboardID
        self.title = title
        self.characterCount = kind == .image ? 0 : text.count
        // Sidecar spill + truncation are decided and applied by ClipboardStore (the only place that
        // also writes the sidecar file); the model defaults to "fully inline, not truncated" and the
        // store mutates these on the constructed value when it spills/ceilings the text.
        self.textFileName = nil
        self.fullTextHash = nil
        self.isTruncated = false
        self.originalCharacterCount = self.characterCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        sourceApp = try container.decode(String.self, forKey: .sourceApp)
        sourceBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier)
        sourceAppPath = try container.decodeIfPresent(String.self, forKey: .sourceAppPath)
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        kind = try container.decodeIfPresent(ClipboardKind.self, forKey: .kind) ?? Self.detectKind(for: text)
        pinboardID = try container.decodeIfPresent(UUID.self, forKey: .pinboardID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        characterCount = try container.decodeIfPresent(Int.self, forKey: .characterCount) ?? text.count
        // Forward-compatible: pre-sidecar history.json lacks these keys → fully-inline defaults.
        textFileName = try container.decodeIfPresent(String.self, forKey: .textFileName)
        fullTextHash = try container.decodeIfPresent(String.self, forKey: .fullTextHash)
        isTruncated = try container.decodeIfPresent(Bool.self, forKey: .isTruncated) ?? false
        originalCharacterCount = try container.decodeIfPresent(Int.self, forKey: .originalCharacterCount) ?? characterCount
    }

    var imageFileURL: URL? {
        guard let imageFileName else { return nil }
        return Self.imageDirectoryURL.appendingPathComponent(imageFileName)
    }

    static var imageDirectoryURL: URL {
        AppPaths.imageDirectoryURL
    }

    static var textDirectoryURL: URL {
        AppPaths.textDirectoryURL
    }

    static func detectKind(for text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return .link
        }
        if trimmed.contains("@"), trimmed.range(of: #"^\S+@\S+\.\S+$"#, options: .regularExpression) != nil {
            return .email
        }
        let hasBracePair = trimmed.contains("{") && trimmed.contains("}")
        let hasCodeKeyword = trimmed.contains("func ") || trimmed.contains("class ") || trimmed.contains("import ")
        if hasBracePair || hasCodeKeyword {
            return .code
        }
        return .text
    }
}
