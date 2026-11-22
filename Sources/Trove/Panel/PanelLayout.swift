import CoreGraphics

/// The panel's spacing, on a 4pt grid: one inset between the panel's edges and its content on every
/// side, the same inset between the toolbar and the cards, and one height for every toolbar control.
enum PanelLayout {
    static let inset: CGFloat = 12
    static let toolbarHeight: CGFloat = 28
    /// The panel's height minus the card row: inset, toolbar, inset above the cards, inset below.
    static let chromeHeight = inset * 3 + toolbarHeight
}
