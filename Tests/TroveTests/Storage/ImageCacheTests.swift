import AppKit
import Carbon
import Testing
@testable import Trove

struct ImageFitTests {
    @Test func neverUpscalesAndKeepsTheAspect() {
        let fitted = ImageFit.size(of: CGSize(width: 400, height: 200), within: CGSize(width: 1000, height: 1000), atLeast: .zero)
        #expect(fitted == CGSize(width: 400, height: 200))
        let shrunk = ImageFit.size(of: CGSize(width: 2000, height: 1000), within: CGSize(width: 1000, height: 1000), atLeast: .zero)
        #expect(shrunk == CGSize(width: 1000, height: 500))
    }

    @Test func floorStopsSliversButBoundsWin() {
        let sliver = ImageFit.size(of: CGSize(width: 2000, height: 10), within: CGSize(width: 1000, height: 1000), atLeast: CGSize(width: 200, height: 130))
        #expect(sliver == CGSize(width: 1000, height: 130))
        let tight = ImageFit.size(of: CGSize(width: 50, height: 50), within: CGSize(width: 150, height: 100), atLeast: CGSize(width: 200, height: 130))
        #expect(tight == CGSize(width: 150, height: 100))
    }
}
