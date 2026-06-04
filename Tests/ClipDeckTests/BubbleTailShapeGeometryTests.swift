import SwiftUI
import Testing
@testable import ClipDeck

/// Deterministic, dependency-free regression guard for the Quick Look bubble outline — the shape we
/// iterated on the most (seam, size, the Dock-style ogee tail). Asserts the *geometry* of the path
/// (tail at bottom-center, rounded top corners, tip reaching the bottom edge) rather than pixels, so
/// it's CI-safe and not environment-sensitive.
struct BubbleTailShapeGeometryTests {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 140)
    private func makePath(tailHeight: CGFloat = 8) -> Path {
        BubbleTailShape(tailHeight: tailHeight).path(in: rect)
    }

    @Test func fillsItsRectAndTheTailReachesTheBottom() {
        let bounds = makePath().boundingRect
        #expect(abs(bounds.width - 200) < 1)
        #expect(abs(bounds.maxY - 140) < 1)   // the tail tip reaches the bottom edge
        #expect(bounds.minY <= 1)             // body starts at the top edge
    }

    @Test func tailIsANarrowCenteredSpike() {
        let path = makePath()
        // Filled at the tail's center column, below the body's bottom edge (132)...
        #expect(path.contains(CGPoint(x: 100, y: 137)))
        // ...but empty off to the sides at that depth (a narrow tail, not a full-width bar).
        #expect(!path.contains(CGPoint(x: 150, y: 136)))
        #expect(!path.contains(CGPoint(x: 50, y: 136)))
    }

    @Test func topCornersAreRounded() {
        let path = makePath()
        // The extreme top corners are clipped by the 16pt corner radius...
        #expect(!path.contains(CGPoint(x: 1, y: 1)))
        #expect(!path.contains(CGPoint(x: 199, y: 1)))
        // ...while the body interior and the straight middle of the top edge are filled.
        #expect(path.contains(CGPoint(x: 100, y: 60)))
        #expect(path.contains(CGPoint(x: 100, y: 5)))
    }

    @Test func tailHeightSetsTheBodyBottom() {
        let path = makePath(tailHeight: 8)
        #expect(path.contains(CGPoint(x: 100, y: 130)))   // just inside the body bottom (132)
        #expect(!path.contains(CGPoint(x: 100, y: 141)))  // below the tip → outside
    }
}
