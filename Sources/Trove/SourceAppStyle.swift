import SwiftUI

/// How a card shows its source app when the app's real icon can't be read: the app's name, its
/// initials, and an identity hue picked from `Theme.Hue` by the name's hash (stable per app).
struct SourceAppStyle {
    let displayName: String
    let color: Color
    let initials: String

    static func resolve(for sourceApp: String) -> SourceAppStyle {
        let trimmed = sourceApp.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "App" : trimmed
        let hash = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return SourceAppStyle(
            displayName: name,
            color: Theme.Hue.all[abs(hash) % Theme.Hue.all.count],
            initials: initials(from: name)
        )
    }

    private static func initials(from name: String) -> String {
        let value = String(name.split { !$0.isLetter && !$0.isNumber }.prefix(2).compactMap(\.first)).uppercased()
        return value.isEmpty ? "A" : value
    }
}
