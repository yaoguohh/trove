import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Start as a menu-bar accessory so the Dock never shows a transient icon before
// AppDelegate applies the user's persisted background-mode preference.
app.setActivationPolicy(.accessory)
app.run()
