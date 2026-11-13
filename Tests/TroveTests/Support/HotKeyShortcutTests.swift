import AppKit
import Carbon
import Testing
@testable import Trove

@MainActor
struct ShortcutSymbolTests {
    @Test func modifiersRoundTripThroughCarbonMasks() {
        let flags: NSEvent.ModifierFlags = [.command, .shift]
        let carbon = ModifierKey.carbon(from: flags)
        #expect(ModifierKey.symbols(carbon: carbon) == ["⇧", "⌘"])
        #expect(ModifierKey.symbols(flags: flags) == ["⇧", "⌘"])
    }

    @Test func keysThatPrintNothingHaveFixedSymbols() {
        #expect(KeyCodeNames.symbol(for: UInt32(kVK_Space)) == "␣")
        #expect(KeyCodeNames.symbol(for: UInt32(kVK_F5)) == "F5")
    }

    @Test func characterKeysShowWhatTheLayoutTypes() {
        let symbol = KeyCodeNames.symbol(for: UInt32(kVK_ANSI_V))
        #expect(symbol.count == 1)
        #expect(symbol == symbol.uppercased())
    }
}
