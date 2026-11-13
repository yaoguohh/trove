import SwiftUI

/// Pinboard colors by stored NAME ("red", "blue", …), so the hues can change without migrating data.
/// The hues themselves are `Theme.Hue`.
enum PinboardColor {
    static let palette = ["red", "orange", "yellow", "green", "teal", "blue", "purple"]

    static func color(named name: String) -> Color {
        switch name {
        case "red": Theme.Hue.red
        case "orange": Theme.Hue.orange
        case "yellow": Theme.Hue.yellow
        case "green": Theme.Hue.green
        case "teal": Theme.Hue.teal
        case "purple": Theme.Hue.purple
        case "pink": Theme.Hue.pink
        default: Theme.Hue.blue
        }
    }

    static func nextColorName(forExistingCount count: Int) -> String {
        palette[count % palette.count]
    }
}
