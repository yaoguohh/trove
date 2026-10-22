import AppKit
import SwiftUI

/// Hosts SwiftUI content in a way that accepts the very first mouse event even when
/// the app isn't frontmost. A borderless non-activating panel's first click is
/// otherwise consumed making the window key instead of being dispatched to the
/// content, which made the first card drag do nothing (you had to click/drag twice).
final class ClickThroughHostingController<Content: View>: NSHostingController<Content> {
    override init(rootView: Content) {
        super.init(rootView: rootView)
        // The panel owns its dimensions. Unmounting its root must not replace the
        // window's size constraints with the empty view's zero-size constraints.
        sizingOptions = []
        (view as? NSHostingView<Content>)?.sizingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = ClickThroughHostingView(rootView: rootView)
    }
}

private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
