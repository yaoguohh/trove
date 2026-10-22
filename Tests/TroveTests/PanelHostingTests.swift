import AppKit
import SwiftUI
import Testing
@testable import Trove

@MainActor
@Suite(.serialized)
struct PanelHostingTests {
    @Test func hiddenPanelUnmountsContentAndReopens() async throws {
        let (controller, directory) = makePanel()
        defer {
            controller.hide()
            try? FileManager.default.removeItem(at: directory)
        }
        controller.show()
        let hosting = try #require(hostingView())
        #expect(hosting.rootView != nil)
        #expect(hosting.sizingOptions.isEmpty)
        controller.hide()
        #expect(!controller.isVisible)
        #expect(hosting.rootView == nil)
        try await Task.sleep(for: .milliseconds(100))
        controller.show()
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.isVisible)
        #expect(hosting.rootView != nil)
        #expect((hosting.window?.frame.width ?? 0) >= 720)
        #expect((hosting.window?.frame.height ?? 0) >= 240)
        #expect(hosting.window?.firstResponder is NSTextView)
        controller.hide(animated: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!controller.isVisible)
        #expect(hosting.rootView == nil)
    }

    @Test func reopeningDuringFadeKeepsContentMounted() async throws {
        let (controller, directory) = makePanel()
        defer {
            controller.hide()
            try? FileManager.default.removeItem(at: directory)
        }
        controller.show()
        let hosting = try #require(hostingView())
        controller.hide(animated: true)
        controller.show()
        try await Task.sleep(for: .milliseconds(350))
        #expect(controller.isVisible)
        #expect(hosting.rootView != nil)
        #expect(hosting.window?.alphaValue == 1)
    }

    private func hostingView() -> NSHostingView<ClipboardPanelView?>? {
        NSApplication.shared.windows.filter(\.isVisible)
            .flatMap { $0.contentView?.subviews ?? [] }
            .compactMap { $0 as? NSHostingView<ClipboardPanelView?> }.first
    }

    private func makePanel() -> (ClipboardPanelController, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrovePanelTests-\(UUID().uuidString)")
        let store = ClipboardStore(storeURL: directory.appendingPathComponent("history.json"))
        store.add(text: "Panel lifecycle fixture", sourceApp: "Test")
        return (ClipboardPanelController(store: store, monitor: ClipboardMonitor(store: store)), directory)
    }
}
