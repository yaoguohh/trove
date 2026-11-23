import AppKit
import SwiftUI

/// An app icon drawn so its visible rounded square fills `size`.
///
/// macOS icon art follows Apple's grid: the rounded square is 824 of a 1024 canvas, with 100 of
/// transparent margin on every side. Laid out at canvas size, that margin puts the visible edge about
/// 10% inside the frame, so the icon never lines up with the text and edges around it. Here the image
/// is drawn larger by the margin and the frame is the rounded square itself; alignment then works on
/// the frame like any other shape.
struct AppIconImage: View {
    /// The visible rounded square's share of the icon canvas on Apple's grid.
    static let squareFraction: CGFloat = 824.0 / 1024

    let image: NSImage
    let size: CGFloat

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size / Self.squareFraction, height: size / Self.squareFraction)
            .frame(width: size, height: size)
    }
}
