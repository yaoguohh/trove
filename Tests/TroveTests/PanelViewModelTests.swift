import Foundation
import Testing
@testable import Trove

@MainActor
private func makeModel(itemCount: Int) -> PanelViewModel {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("TroveVMTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = ClipboardStore(storeURL: dir.appendingPathComponent("history.json"))
    for i in 0..<itemCount {
        store.add(text: "item-\(i)", sourceApp: "Test")
    }
    return PanelViewModel(store: store)
}

@MainActor
struct PanelViewModelSelectionTests {
    @Test func selectFirstPicksTheTopItem() {
        let model = makeModel(itemCount: 4)
        model.selectFirst()
        #expect(model.selectedID == model.filteredItems.first?.id)
    }

    @Test func moveSelectionAdvancesAndClampsAtEnds() {
        let model = makeModel(itemCount: 4)
        let items = model.filteredItems
        #expect(items.count == 4)
        model.selectFirst()

        model.moveSelection(by: 1)
        #expect(model.selectedID == items[1].id)

        // Clamp at the top — can't move before the first.
        model.moveSelection(by: -5)
        #expect(model.selectedID == items[0].id)

        // Clamp at the bottom — a big "page" jump (⌘→) can't overshoot the last.
        model.moveSelection(by: 99)
        #expect(model.selectedID == items.last?.id)
    }

    @Test func moveSelectionOnEmptyListIsSafe() {
        let model = makeModel(itemCount: 0)
        model.selectFirst()
        #expect(model.selectedID == nil)
        model.moveSelection(by: 1)   // must not crash or set a bogus id
        #expect(model.selectedID == nil)
    }

    @Test func filteredItemsFollowQueryAndStoreChanges() {
        let model = makeModel(itemCount: 4)   // item-0 … item-3, newest first
        #expect(model.filteredItems.count == 4)

        model.query = "item-2"
        #expect(model.filteredItems.map(\.text) == ["item-2"])

        // A new clip arriving while a query is active is filtered into the published result.
        model.store.add(text: "item-22", sourceApp: "Test")
        #expect(model.filteredItems.map(\.text) == ["item-22", "item-2"])

        model.query = ""
        #expect(model.filteredItems.count == 5)

        model.filter.kind = .image
        #expect(model.filteredItems.isEmpty)
    }

    @Test func selectionChangeHookFiresOnlyOnRealChange() {
        let model = makeModel(itemCount: 3)
        var fired = 0
        model.onSelectionChange = { fired += 1 }

        model.selectFirst()
        let afterFirst = fired
        #expect(afterFirst >= 1)

        // Re-assigning the same id is a no-op (the didSet guards on oldValue).
        model.selectedID = model.selectedID
        #expect(fired == afterFirst)

        // A genuine move fires exactly once more.
        model.moveSelection(by: 1)
        #expect(fired == afterFirst + 1)
    }
}
