import SwiftUI

/// Selection/search state for the clipboard panel, owned by the controller so its keyboard
/// monitor can drive it (move selection, paste the highlighted card) and the SwiftUI view
/// can render it. Keeping this in an ObservableObject — rather than the View's `@State` — is
/// what lets the app-level NSEvent monitor read/mutate selection without focus-timing hacks.
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var query = ""
    @Published var filter = ClipboardSearchFilter()
    @Published var selectedID: ClipboardItem.ID? {
        didSet {
            guard selectedID != oldValue else { return }
            onSelectionChange?()
        }
    }
    /// Called (on the main actor) whenever the selection changes from any source — keyboard, hover,
    /// or programmatic — so the controller can keep an open Quick Look peek bubble re-fitted to it.
    var onSelectionChange: (() -> Void)?
    /// Bumped on every panel (re)show so the view can re-focus the search field — the SwiftUI view
    /// persists across orderOut/orderFront and `onAppear` fires only once.
    @Published private(set) var showToken = 0
    /// The card whose title is being renamed inline (nil = not renaming). Drives the rename editor's
    /// visibility; the actual keyboard focus is the view's single PanelFocus authority.
    @Published var renamingItemID: ClipboardItem.ID?

    let store: ClipboardStore

    init(store: ClipboardStore) {
        self.store = store
    }

    var filteredItems: [ClipboardItem] {
        store.matches(query: query, filter: filter)
    }

    /// The card a paste/Return acts on: the explicit selection, else the top result.
    var selectedItem: ClipboardItem? {
        if let selectedID, let item = filteredItems.first(where: { $0.id == selectedID }) {
            return item
        }
        return filteredItems.first
    }

    /// Fresh state for a new presentation: empty search, full history, the top item
    /// pre-highlighted (so the ring always shows what Return will paste).
    func prepareForShow() {
        query = ""
        filter = ClipboardSearchFilter()
        renamingItemID = nil
        selectFirst()
        showToken &+= 1
    }

    func selectFirst() {
        selectedID = filteredItems.first?.id
    }

    func moveSelection(by offset: Int) {
        let items = filteredItems
        guard !items.isEmpty else { return }
        let current = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }
}
