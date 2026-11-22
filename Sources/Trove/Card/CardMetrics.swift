import CoreGraphics

struct CardMetrics {
    let width: CGFloat
    let height: CGFloat
    let headerHeight: CGFloat
    let contentHeight: CGFloat
    let footerHeight: CGFloat
    let iconSize: CGFloat
    let cornerRadius: CGFloat
    let sidePadding: CGFloat
    let topPadding: CGFloat
    let bottomPadding: CGFloat
    let spacing: CGFloat
    let titleSize: CGFloat
    let bodySize: CGFloat
    let footerSize: CGFloat

    /// Reference card footprint used by `PanelController.visibleCardCount()` to estimate
    /// how many cards fit across the panel (the ⌘←/⌘→ page size). These mirror the enlarged card's
    /// typical on-screen width/spacing (the live size is computed from container height in `init`);
    /// keeping them here means the page-size estimate can't silently drift from the card geometry.
    static let referenceCardWidth: CGFloat = 296
    static let referenceCardSpacing: CGFloat = 18

    /// Card height range. The panel's height is derived from it (`PanelController`), so the row is
    /// always exactly `inset` from the toolbar above and the panel edge below.
    static let minHeight: CGFloat = 176
    static let maxHeight: CGFloat = 264

    /// `containerSize` is the area under the toolbar; `inset` is kept on every side of the row.
    init(containerSize: CGSize, inset: CGFloat) {
        topPadding = inset
        bottomPadding = inset
        sidePadding = inset
        // A 1.12 aspect so each card shows a useful amount of content.
        height = min(Self.maxHeight, max(Self.minHeight, containerSize.height - 2 * inset))
        width = min(330, max(220, height * 1.12))
        headerHeight = min(48, max(38, height * 0.16))
        footerHeight = min(32, max(26, height * 0.13))
        contentHeight = max(72, height - headerHeight - footerHeight)
        iconSize = min(44, max(36, headerHeight * 0.92))
        // Fixed radius (Theme.Radius.card): nothing scales its radius with its size, so cards and the
        // panel (16) stay in one family at every display size.
        cornerRadius = Theme.Radius.card
        spacing = min(22, max(14, width * 0.06))
        titleSize = min(16, max(14, height * 0.048))
        bodySize = min(17, max(14, height * 0.050))
        footerSize = min(11, max(10, height * 0.033))
    }
}
