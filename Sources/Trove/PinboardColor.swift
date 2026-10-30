import SwiftUI

/// Single source of truth for pinboard color names. The stored value is the NAME ("red", "blue", …)
/// so this mapping can change without migrating data; the colors are anthracite's bright terminal
/// set — seven hues already balanced against the dark card surface, distinguishable without
/// shouting (the previous palette was the saturated system colors).
enum PinboardColor {
    static let palette = ["red", "orange", "yellow", "green", "teal", "blue", "purple"]

    static func color(named name: String) -> Color {
        switch name {
        case "red": Color(hex: 0xEF7A72)
        case "orange": Color(hex: 0xE8734A)
        case "yellow": Color(hex: 0xF0D88A)
        case "green": Color(hex: 0x9CC98A)
        case "teal": Color(hex: 0x8CD0C2)
        case "purple": Color(hex: 0xD0AADE)
        // Legacy name from the old palette; keep it readable for existing pinboards.
        case "pink": Color(hex: 0xE2A3C0)
        default: Color(hex: 0x9CC2E8)   // "blue"
        }
    }

    static func nextColorName(forExistingCount count: Int) -> String {
        palette[count % palette.count]
    }
}
