import Combine
import SwiftUI

/// Selection/search state for the clipboard panel, owned by the controller so its keyboard
/// monitor can drive it (move selection, paste the highlighted card) and the SwiftUI view
/// can render it. Keeping this in an ObservableObject — rather than the View's `@State` — is
/// what lets the app-level NSEvent monitor read/mutate selection without focus-timing hacks.
@MainActor
final class PanelViewModel: ObservableObject {
    /// A new query or filter always re-selects the top result, so Return pastes what is shown first.
    @Published var query = "" {
        didSet { if query != oldValue { refilter(); selectFirst() } }
    }
    @Published var filter = ClipFilter() {
        didSet { if filter != oldValue { refilter(); selectFirst() } }
    }
    @Published var selectedID: Clip.ID? {
        didSet {
            guard selectedID != oldValue else { return }
            onSelectionChange?()
        }
    }
    /// The search result, recomputed exactly once per change of query / filter / history — never
    /// inside a view body. The panel reads it several times per render, and `ClipSearch` scans up to
    /// 20k characters per item, so a computed property here cost ~50ms × reads per keystroke at a
    /// full history.
    @Published private(set) var filteredItems: [Clip] = []
    /// Called (on the main actor) whenever the selection changes from any source — keyboard, hover,
    /// or programmatic. The controller uses it to close the peek bubble, which never follows a change.
    var onSelectionChange: (() -> Void)?
    /// Bumped on every panel (re)show to re-focus search and bring the row back to the first card;
    /// the view stays mounted between shows, so `onAppear` does not run again.
    @Published private(set) var showToken = 0
    /// When the panel was last shown: what every card's "5 min ago" is measured against.
    @Published private(set) var shownAt = Date()
    /// Bumped to re-assert search-field focus WITHOUT a full prepareForShow (which would also clear
    /// the query). Deleting a card can make SwiftUI drop focus; re-claiming it keeps printable input
    /// editing the query. Navigation/action keys are independently handled by the window monitor.
    @Published private(set) var refocusToken = 0
    /// The card whose title is being renamed inline (nil = not renaming). Drives the rename editor's
    /// visibility; the actual keyboard focus is the view's single PanelFocus authority.
    @Published var renamingItemID: Clip.ID?

    let store: ClipStore
    private var itemsSubscription: AnyCancellable?
    /// While the panel is hidden a history change only marks the result stale; it is recomputed on the
    /// next show, so a copy made while the panel is away costs the hidden view nothing.
    private var isHidden = false
    private var resultIsStale = false
    /// Set when a show moves the selection, so the view jumps to it instead of scrolling there.
    private var jumpsToSelection = false

    init(store: ClipStore) {
        self.store = store
        filteredItems = ClipSearch.filter(store.items, query: "", filter: ClipFilter())
        // `$items` emits the NEW array (willSet semantics), so filter the published value rather than
        // `store.items`, which still holds the old one at that moment.
        itemsSubscription = store.$items.sink { [weak self] items in
            guard let self else { return }
            if isHidden {
                resultIsStale = true
            } else {
                refilter(items: items)
            }
        }
    }

    private func refilter(items: [Clip]? = nil) {
        filteredItems = ClipSearch.filter(items ?? store.items, query: query, filter: filter)
    }

    /// The card a paste/Return acts on: the explicit selection, else the top result.
    var selectedItem: Clip? {
        if let selectedID, let item = filteredItems.first(where: { $0.id == selectedID }) {
            return item
        }
        return filteredItems.first
    }

    /// Fresh state for a new presentation: empty search, full history, the top item
    /// pre-highlighted (so the ring always shows what Return will paste).
    func prepareForShow() {
        isHidden = false
        // A fresh presentation, not a change to watch: no reflow or scroll animation.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            query = ""
            filter = ClipFilter()
            if resultIsStale {
                refilter()
                resultIsStale = false
            }
            renamingItemID = nil
            if selectedID != filteredItems.first?.id { jumpsToSelection = true }
            selectFirst()
            shownAt = Date()
            showToken &+= 1
        }
    }

    func didHide() {
        isHidden = true
    }

    /// Whether the latest selection change came from a show (and should be jumped to, not animated).
    /// Reading it clears it.
    func consumeJumpToSelection() -> Bool {
        defer { jumpsToSelection = false }
        return jumpsToSelection
    }

    /// Pre-select the leading card on summon (and on each search) so it's always the fully-visible
    /// first card the auto-scroll keeps at the leading edge.
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

    /// Back to the full, unfiltered history.
    func resetFilters() {
        query = ""
        filter = ClipFilter()
    }

    /// Delete a card and select the neighbor now at the same position, so repeated deletes keep the
    /// user's place. Deleting can make SwiftUI drop the search field's focus, so it is re-claimed.
    func delete(_ item: Clip) {
        let index = filteredItems.firstIndex { $0.id == item.id } ?? 0
        store.delete(item)
        let remaining = filteredItems
        selectedID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
        requestSearchFocus()
    }

    /// Restore the most recently deleted card (⌘Z) and select it so the recovery is visible. If the
    /// active filter hides the restored card, fall back to the full history — otherwise the selection
    /// would point off-screen and the next paste would act on a different card.
    func undoDelete() {
        guard let restored = store.undoDelete() else { return }
        if !filteredItems.contains(where: { $0.id == restored.id }) {
            resetFilters()
        }
        selectedID = restored.id
    }
}
