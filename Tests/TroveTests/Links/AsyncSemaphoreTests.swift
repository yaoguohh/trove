import Foundation
import Testing
@testable import Trove

actor ConcurrencyTracker {
    private(set) var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func exit() { current -= 1 }
}

struct AsyncSemaphoreTests {
    @Test func capsSimultaneousHolders() async {
        let gate = AsyncSemaphore(limit: 2)
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await gate.acquire()
                    await tracker.enter()
                    try? await Task.sleep(nanoseconds: 15_000_000)
                    await tracker.exit()
                    await gate.release()
                }
            }
        }
        #expect(await tracker.peak <= 2)
        #expect(await tracker.peak >= 1)
        #expect(await tracker.current == 0)
    }
}
