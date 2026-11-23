import CoreGraphics

/// A card's geometry, in one of three sizes picked by the display the panel shows on (see `Size`).
/// Each size is designed on its own, the way the macOS sidebar's small, medium and large sizes are: the
/// type steps along the macOS text styles, the icons along their usual sizes, and a larger card holds
/// more text rather than the same text enlarged. The insets, hairlines and corners stay the same in
/// every size. See docs/adr/0020-card-sizes.md.
struct CardMetrics {
    /// The card sizes. A display tall in points (a large display set to "More Space") sits farther away
    /// and leaves the panel a small share of its height, so it gets a larger card; a laptop gets the
    /// small one.
    enum Size: CaseIterable {
        case small, medium, large

        /// The size for a display `height` points tall (its whole frame, menu bar and Dock included).
        init(screenHeight height: CGFloat) {
            self = height < 1200 ? .small : height < 1600 ? .medium : .large
        }
    }

    let size: Size
    let width: CGFloat
    let height: CGFloat
    /// The meta row's source app icon, its visible rounded square (`AppIconImage`); the row is this tall.
    let iconSize: CGFloat
    /// A link card's site icon, beside the page title.
    let siteIconSize: CGFloat
    /// The clip's name, in the semibold weight.
    let nameSize: CGFloat
    /// The time beside the name.
    let detailSize: CGFloat
    /// A link card's page title, in the semibold weight.
    let titleSize: CGFloat
    let bodySize: CGFloat
    /// Small print inside the body (a link's URL and host).
    let captionSize: CGFloat

    /// The card's inset on the left, right and bottom: the meta row and the body keep it from those edges.
    /// Equal to the radius, so content keeps the same distance from the corner arcs as from the straight
    /// edges.
    let contentInset: CGFloat = Theme.Radius.card
    /// Above and below the meta row: from the card's top edge to the row, and from the row to the body.
    /// Equal, so the row sits centered between the edge and the content (14 above and 8 below read as
    /// sinking onto the content).
    let metaSpace: CGFloat = 8
    /// Fixed radius (Theme.Radius.card), one family with the panel's (16).
    let cornerRadius: CGFloat = Theme.Radius.card

    init(size: Size) {
        self.size = size
        // Type: macOS text styles — Callout 12, Body 13, Title 3 15, Title 2 17; Subheadline 11 and
        // Callout 12 for the small print.
        switch size {
        case .small:
            width = 200; height = 176
            iconSize = 18; siteIconSize = 24
            nameSize = 12; detailSize = 11; titleSize = 13; bodySize = 12; captionSize = 11
        case .medium:
            width = 224; height = 200
            iconSize = 20; siteIconSize = 26
            nameSize = 13; detailSize = 11; titleSize = 15; bodySize = 13; captionSize = 11
        case .large:
            width = 272; height = 240
            iconSize = 24; siteIconSize = 32
            nameSize = 15; detailSize = 12; titleSize = 17; bodySize = 15; captionSize = 12
        }
    }

    /// The body's height: the card less the meta row, the space around it and the bottom inset.
    var contentHeight: CGFloat { height - metaSpace * 2 - iconSize - contentInset }
    /// How far the source app's color glows from the top-left corner before fading out.
    var glowRadius: CGFloat { width * 0.9 }
}
