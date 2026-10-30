import os

/// One `Logger` per subsystem area, so `log stream --predicate 'subsystem == "io.github.yaoguohh.trove"'`
/// (optionally `AND category == "clipboard"`) shows exactly Trove's output. Replaces the scattered
/// `NSLog` calls, which had no subsystem and could not be filtered.
enum Log {
    private static let subsystem = "io.github.yaoguohh.trove"

    static let store = Logger(subsystem: subsystem, category: "store")
    static let clipboard = Logger(subsystem: subsystem, category: "clipboard")
    static let images = Logger(subsystem: subsystem, category: "images")
    static let paste = Logger(subsystem: subsystem, category: "paste")
    static let links = Logger(subsystem: subsystem, category: "links")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
