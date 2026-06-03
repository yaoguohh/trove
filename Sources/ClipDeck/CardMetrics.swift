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

    /// Reference card footprint used by `ClipboardPanelController.position()` to size the panel and
    /// estimate how many cards fit on screen. These mirror the enlarged card's typical on-screen
    /// width/spacing (the live size is computed from container height in `init`); keeping them here
    /// means panel sizing and card geometry can't silently drift apart.
    static let referenceCardWidth: CGFloat = 296
    static let referenceCardSpacing: CGFloat = 18

    init(containerSize: CGSize) {
        topPadding = min(13, max(9, containerSize.height * 0.035))
        bottomPadding = min(24, max(16, containerSize.height * 0.075))
        let usableHeight = max(158, containerSize.height - topPadding - bottomPadding - 8)
        // Larger cards: taller cap (212 → 264) and a wider aspect (was ≈square at 0.98; now
        // 1.12) so each card shows more content. Panel height (ClipboardPanelController) was
        // raised in step so the card can actually reach these caps on a big display.
        height = min(264, max(176, usableHeight))
        width = min(330, max(220, height * 1.12))
        headerHeight = min(48, max(38, height * 0.16))
        footerHeight = min(32, max(26, height * 0.13))
        contentHeight = max(72, height - headerHeight - footerHeight)
        iconSize = min(44, max(36, headerHeight * 0.92))
        cornerRadius = min(20, max(15, height * 0.055))
        sidePadding = min(28, max(16, containerSize.width * 0.015))
        spacing = min(22, max(14, width * 0.06))
        titleSize = min(16, max(14, height * 0.048))
        bodySize = min(17, max(14, height * 0.050))
        footerSize = min(11, max(10, height * 0.033))
    }
}
