import AppKit
import SwiftUI

/// Hosts SwiftUI content in a way that accepts the very first mouse event even when
/// the app isn't frontmost. A borderless non-activating panel's first click is
/// otherwise consumed making the window key instead of being dispatched to the
/// content, which made the first card drag do nothing (you had to click/drag twice).
final class ClickThroughHostingController<Content: View>: NSHostingController<Content> {
    override func loadView() {
        view = ClickThroughHostingView(rootView: rootView)
    }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
