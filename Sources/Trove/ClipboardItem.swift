import CryptoKit
import Foundation

enum ClipboardKind: String, Codable, CaseIterable, Identifiable {
    case text
    case link
    case code
    case email
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: String(localized: "Text")
        case .link: String(localized: "Link")
        case .code: String(localized: "Code")
        case .email: String(localized: "Email")
        case .image: String(localized: "Image")
        }
    }

    var symbolName: String {
        switch self {
        case .text: "doc.text"
        case .link: "link"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .email: "envelope"
        case .image: "photo"
        }
    }
}

/// A named group of pinned clips. Pinboards are ordered by their position in the store's array.
struct Pinboard: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// A `PinboardColor` name, stored by name so the hues can change without migrating data.
    var colorName: String

    init(id: UUID = UUID(), name: String, colorName: String) {
        self.id = id
        self.name = name
        self.colorName = colorName
    }
}

struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var text: String
    var sourceApp: String
    var sourceBundleIdentifier: String?
    var sourceAppPath: String?
    var imageFileName: String?
    /// Card-sized rendition of an image clip (`ImageIngest.thumbnailMaxPixelSize`). Equal to `imageFileName`
    /// when the original is already small; nil for legacy items until `backfillThumbnails` runs.
    var thumbnailFileName: String?
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
    /// The clip's content identity, the single key behind "one card per content": SHA-256 of the
    /// whitespace-trimmed text for text clips, of the stored PNG bytes for image clips. Dedup compares
    /// only this, so it never reads a sidecar and never confuses a display string with content. nil
    /// only for image clips stored before identities existed — those simply never dedup.
    var contentHash: String?
    /// True only when the content was so large it hit `ultimateSidecarCeiling` and was hard-truncated
    /// (the rare case where paste loses the tail). Surfaced as a "Truncated" footer chip.
    var isTruncated: Bool
    /// The clip's true source length in characters (== `characterCount` except for ceiling-truncated
    /// clips, where `characterCount` is also the original length so the footer stays honest).
    var originalCharacterCount: Int

    /// Upper bound on the number of characters `preview` derives from the full text. A card only
    /// shows a handful of lines, so capping the SOURCE keeps `preview` (and everything downstream of
    /// it — card body, `displayTitle`, the drag image, the preview-window title) O(cap) instead of
    /// O(full text); without it every re-render would build a newline-replaced copy of a multi-MB clip.
    static let displayPreviewCap = 8_000

    var preview: String {
        // Take the prefix BEFORE the O(n) transforms so the work is bounded by `displayPreviewCap`,
        // not by the (possibly multi-MB) full text. `prefix(_:)` walks at most `displayPreviewCap`
        // characters; the copy then happens only on that already-bounded substring.
        text.prefix(Self.displayPreviewCap)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The card's name: the user's custom title, else the kind label ("Text", "Link", …). Shown in the
    /// card header and read first by VoiceOver.
    var name: String {
        if let title, !title.isEmpty { return title }
        return kind.title
    }

    /// The best one-line label: the custom title, else the content preview, else the kind label. Used
    /// where the card itself isn't visible — window titles, the drag placeholder.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
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

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Identity of a text clip: surrounding whitespace is not content (editors and terminals toggle a
    /// trailing newline constantly), so a re-copy that differs only by it is the same clip.
    static func textIdentity(_ text: String) -> String {
        hash(Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8))
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
        title: String? = nil,
        contentHash: String? = nil
    ) {
        self.id = id
        self.text = text
        self.sourceApp = sourceApp
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.sourceAppPath = sourceAppPath
        self.imageFileName = imageFileName
        self.thumbnailFileName = nil
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
        self.contentHash = contentHash ?? (kind == .image ? nil : Self.textIdentity(text))
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
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        isPinned = try container.decode(Bool.self, forKey: .isPinned)
        // A kind this version doesn't know (a removed case, or one from a newer version) is
        // re-detected rather than failing the whole document.
        kind = ClipboardKind(rawValue: try container.decode(String.self, forKey: .kind))
            ?? Self.detectKind(for: text)
        pinboardID = try container.decodeIfPresent(UUID.self, forKey: .pinboardID)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        textFileName = try container.decodeIfPresent(String.self, forKey: .textFileName)
        isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        originalCharacterCount = try container.decode(Int.self, forKey: .originalCharacterCount)

        // Migrations from earlier document versions (see `StoreDocument.currentVersion`); the store
        // writes the upgraded document back once.
        // Version 1: image clips carried the English placeholder "Image" as content and title, and
        // only sidecar-spilled text clips had an identity (as `fullTextHash`).
        if kind == .image {
            if text == "Image" { text = "" }
            if title == "Image" { title = nil }
        }
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash)
            ?? legacy.decodeIfPresent(String.self, forKey: .fullTextHash)
            ?? (kind == .image ? nil : Self.textIdentity(text))
        // Version 2 and earlier marked any text starting with http(s) as a link, including paragraphs.
        if kind == .link, !Self.isSingleURL(text) {
            kind = Self.detectKind(for: text)
        }
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case fullTextHash
    }

    /// A clip is a link only if it is one bare http(s) URL — no interior whitespace or newline, so a
    /// paragraph that merely starts with a link is text. Bounded so it stays cheap on huge input.
    /// The single definition of "link" for kind detection, capture and the inspect window.
    static func isSingleURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4_000 else { return false }
        guard !trimmed.contains(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) else { return false }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return false }
        return URL(string: trimmed) != nil
    }

    static func detectKind(for text: String) -> ClipboardKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSingleURL(trimmed) {
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
