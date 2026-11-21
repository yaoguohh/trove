import Testing
@testable import Trove

struct WelcomeControllerTests {
    @Test func freshInstallGetsTheWelcome() {
        #expect(WelcomeController.showsAtLaunch(seen: false, historyIsEmpty: true))
    }

    // Upgrading from a version without the welcome: there is history, so it isn't shown on its own.
    @Test func upgradeWithHistorySkipsIt() {
        #expect(!WelcomeController.showsAtLaunch(seen: false, historyIsEmpty: false))
    }

    @Test func shownOnceOnly() {
        #expect(!WelcomeController.showsAtLaunch(seen: true, historyIsEmpty: true))
    }
}
