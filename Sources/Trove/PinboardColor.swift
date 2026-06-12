import SwiftUI

/// Single source of truth for pinboard color names, replacing the scattered
/// name→Color switches and the new-pinboard palette that disagreed with the
/// default pinboards (it was missing "orange").
enum PinboardColor {
    static let palette = ["red", "orange", "yellow", "green", "blue", "purple", "pink"]

    static func color(named name: String) -> Color {
        switch name {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "purple": .purple
        case "pink": .pink
        default: .blue
        }
    }

    static func nextColorName(forExistingCount count: Int) -> String {
        palette[count % palette.count]
    }
}
