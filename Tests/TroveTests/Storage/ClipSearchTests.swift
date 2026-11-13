import Foundation
import Combine
import Testing
@testable import Trove

@MainActor
struct ContentSearchCapTests {
    @Test func matchesScansOnlyCappedPrefix() {
        let (store, _) = makeTempStore()
        // "FINDME" sits at the very start; "TAILONLY" sits well past the 20k search-scan cap.
        let filler = String(repeating: "x", count: 20_000 + 200)
        store.add(text: "FINDME" + filler + "TAILONLY", sourceApp: "X")

        let filter = ClipFilter()
        #expect(!ClipSearch.filter(store.items, query: "FINDME", filter: filter).isEmpty)  // in the scanned prefix → found
        #expect(ClipSearch.filter(store.items, query: "TAILONLY", filter: filter).isEmpty) // past the cap → not surfaced
    }
}
