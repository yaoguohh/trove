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

    var preview: String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }
        return preview.isEmpty ? kind.title : preview
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
    }

    var imageFileURL: URL? {
        guard let imageFileName else { return nil }
        return Self.imageDirectoryURL.appendingPathComponent(imageFileName)
    }

    static var imageDirectoryURL: URL {
        AppPaths.imageDirectoryURL
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
