import AppKit

/// A standalone window — currently just the inspect preview — that a menu-bar app can dismiss with
/// the standard Esc and ⌘W. Trove has no main menu, so there's no File menu to supply the ⌘W "Close"
/// key equivalent and no built-in cancel routing; both are wired to `performClose` here so the window
/// behaves like every other Mac window. (The main spotlight panel is deliberately excluded — its Esc
/// means clear-search / dismiss, handled by its own keyboard model.)
class StandaloneWindow: NSWindow {
    /// Esc → close (the standard cancel action). A subview that wants Esc for itself — e.g. the shortcut
    /// recorder, which eats it via a local key monitor while recording — consumes it upstream, so this
    /// only fires when nothing else claims the key.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            performClose(self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
