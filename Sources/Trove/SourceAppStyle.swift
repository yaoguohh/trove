import SwiftUI

struct SourceAppStyle {
    let displayName: String
    let symbolName: String?
    let color: Color
    let initials: String

    static func resolve(for sourceApp: String) -> SourceAppStyle {
        let name = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = name.lowercased()

        if lowercased.contains("chrome") {
            return SourceAppStyle(displayName: "Chrome", symbolName: "globe", color: Color(red: 0.22, green: 0.53, blue: 0.96), initials: "C")
        }
        if lowercased.contains("safari") {
            return SourceAppStyle(displayName: "Safari", symbolName: "safari", color: Color(red: 0.00, green: 0.50, blue: 0.95), initials: "S")
        }
        if lowercased.contains("wechat") || lowercased.contains("微信") || lowercased.contains("xinwechat") {
            return SourceAppStyle(displayName: "WeChat", symbolName: "message.fill", color: Color(red: 0.11, green: 0.73, blue: 0.31), initials: "W")
        }
        if lowercased.contains("codex") {
            return SourceAppStyle(displayName: "Codex", symbolName: "sparkles", color: Color(red: 0.47, green: 0.33, blue: 0.92), initials: "AI")
        }
        if lowercased.contains("pycharm") {
            return SourceAppStyle(displayName: "PyCharm", symbolName: "hammer.fill", color: Color(red: 0.00, green: 0.68, blue: 0.42), initials: "PC")
        }
        if lowercased.contains("xcode") {
            return SourceAppStyle(displayName: "Xcode", symbolName: "hammer.fill", color: Color(red: 0.04, green: 0.48, blue: 0.93), initials: "X")
        }
        if lowercased.contains("finder") {
            return SourceAppStyle(displayName: "Finder", symbolName: "face.smiling", color: Color(red: 0.15, green: 0.55, blue: 0.95), initials: "F")
        }
        if lowercased.contains("terminal") || lowercased.contains("iterm") || lowercased.contains("warp") {
            return SourceAppStyle(displayName: displayName(from: name, fallback: "Terminal"), symbolName: "terminal.fill", color: Color(red: 0.16, green: 0.17, blue: 0.18), initials: "T")
        }
        if lowercased.contains("cursor") || lowercased.contains("visual studio code") || lowercased.contains("vscode") {
            return SourceAppStyle(displayName: displayName(from: name, fallback: "Code"), symbolName: "chevron.left.forwardslash.chevron.right", color: Color(red: 0.02, green: 0.48, blue: 0.86), initials: "VS")
        }
        if lowercased.contains("slack") {
            return SourceAppStyle(displayName: "Slack", symbolName: "bubble.left.and.bubble.right.fill", color: Color(red: 0.45, green: 0.18, blue: 0.62), initials: "S")
        }

        let displayName = displayName(from: name, fallback: "App")
        return SourceAppStyle(
            displayName: displayName,
            symbolName: nil,
            color: fallbackColor(for: displayName),
            initials: initials(from: displayName)
        )
    }

    private static func displayName(from source: String, fallback: String) -> String {
        source.isEmpty ? fallback : source
    }

    private static func initials(from displayName: String) -> String {
        let words = displayName
            .split { !$0.isLetter && !$0.isNumber }
            .prefix(2)
            .compactMap(\.first)
        let value = String(words).uppercased()
        return value.isEmpty ? "A" : value
    }

    private static func fallbackColor(for displayName: String) -> Color {
        let palette = [
            Color(red: 0.91, green: 0.26, blue: 0.25),
            Color(red: 0.95, green: 0.58, blue: 0.15),
            Color(red: 0.06, green: 0.56, blue: 0.90),
            Color(red: 0.00, green: 0.62, blue: 0.44),
            Color(red: 0.56, green: 0.32, blue: 0.91),
            Color(red: 0.86, green: 0.22, blue: 0.65),
            Color(red: 0.25, green: 0.55, blue: 0.65)
        ]
        let sum = displayName.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        return palette[abs(sum) % palette.count]
    }
}
