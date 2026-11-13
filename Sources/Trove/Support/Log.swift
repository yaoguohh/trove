import os

/// One `Logger` per area under the bundle identifier, so
/// `log stream --predicate 'subsystem == "io.github.yaoguohh.trove"'` (optionally
/// `AND category == "clipboard"`) shows exactly Trove's output.
enum Log {
    private static let subsystem = AppInfo.bundleIdentifier

    static let store = Logger(subsystem: subsystem, category: "store")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let images = Logger(subsystem: subsystem, category: "images")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let links = Logger(subsystem: subsystem, category: "links")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
