import Combine
import SwiftUI

/// Selection/search state for the clipboard panel, owned by the controller so its keyboard
/// monitor can drive it (move selection, paste the highlighted card) and the SwiftUI view
/// can render it. Keeping this in an ObservableObject — rather than the View's `@State` — is
/// what lets the app-level NSEvent monitor read/mutate selection without focus-timing hacks.
@MainActor
final class PanelViewModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { refilter() } }
    }
    @Published var filter = ClipboardSearchFilter() {
        didSet { if filter != oldValue { refilter() } }
    }
    @Published var selectedID: ClipboardItem.ID? {
        didSet {
            guard selectedID != oldValue else { return }
            onSelectionChange?()
        }
    }
    /// The search result, recomputed exactly once per change of query / filter / history — never
    /// inside a view body. The panel reads it several times per render, and `ClipSearch` scans up to
    /// 20k characters per item, so a computed property here cost ~50ms × reads per keystroke at a
    /// full history.
    @Published private(set) var filteredItems: [ClipboardItem] = []
    /// Called (on the main actor) whenever the selection changes from any source — keyboard, hover,
    /// or programmatic — so the controller can keep an open Quick Look peek bubble re-fitted to it.
    var onSelectionChange: (() -> Void)?
    /// Bumped on every panel (re)show to re-focus search, including a re-summon during
    /// the fade when content is still mounted and `onAppear` does not run again.
    @Published private(set) var showToken = 0
    /// Bumped to re-assert search-field focus WITHOUT a full prepareForShow (which would also clear
    /// the query). Deleting a card can make SwiftUI drop focus; re-claiming it keeps printable input
    /// editing the query. Navigation/action keys are independently handled by the window monitor.
    @Published private(set) var refocusToken = 0
    /// The card whose title is being renamed inline (nil = not renaming). Drives the rename editor's
    /// visibility; the actual keyboard focus is the view's single PanelFocus authority.
    @Published var renamingItemID: ClipboardItem.ID?

    let store: ClipboardStore
    private var itemsSubscription: AnyCancellable?

    init(store: ClipboardStore) {
        self.store = store
        filteredItems = ClipSearch.filter(store.items, query: "", filter: ClipboardSearchFilter())
        // `$items` emits the NEW array (willSet semantics), so filter the published value rather than
        // `store.items`, which still holds the old one at that moment.
        itemsSubscription = store.$items.sink { [weak self] items in
            self?.refilter(items: items)
        }
    }

    private func refilter(items: [ClipboardItem]? = nil) {
        filteredItems = ClipSearch.filter(items ?? store.items, query: query, filter: filter)
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

    /// Pre-select the leading card on summon (and on each search) so it's always the fully-visible
    /// first card the auto-scroll keeps at the leading edge. (Usage is tracked in `lastUsedAt` for a
    /// future opt-in "Most Used" mode, but it deliberately does NOT bias this default selection — doing
    /// so picked a mid-strip card and the centering auto-scroll then clipped the first card off-screen.)
    func selectFirst() {
        selectedID = filteredItems.first?.id
    }

    /// Ask the view to re-focus the search field (see `refocusToken`).
    func requestSearchFocus() {
        refocusToken &+= 1
    }

    func moveSelection(by offset: Int) {
        let items = filteredItems
        guard !items.isEmpty else { return }
        let current = selectedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let next = min(max(current + offset, 0), items.count - 1)
        selectedID = items[next].id
    }
}
