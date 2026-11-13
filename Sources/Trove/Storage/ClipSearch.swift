import Foundation

/// The panel's scope chips: an optional kind and an optional pinboard (nil = everything).
struct ClipFilter: Equatable {
    var kind: ClipKind?
    var pinboardID: UUID?
}

/// Pure filtering of an already-sorted history for the panel's search box and scope chips. Lives
/// apart from `ClipStore` (persistence, dedup, undo) so the per-keystroke cost is one obvious
/// function, and so `PanelViewModel` can run it over the exact array the store just published.
enum ClipSearch {
    /// Max characters of a clip's text scanned per item per query. Bounds search to O(cap) so a huge
    /// clip can't make every keystroke walk a multi-MB string. A clip's stored `text` is itself
    /// bounded by the sidecar cap, but capping the scan independently means a future change to that
    /// cap can't silently re-introduce an unbounded per-keystroke scan. Documented limitation: a
    /// match that occurs ONLY past this prefix (in a clip's sidecar tail) won't surface.
    static let scanCap = 20_000

    /// `items` must already be in display order (pinned first, newest first) — `ClipStore`
    /// maintains that invariant on every mutation, so nothing is re-sorted here.
    static func filter(_ items: [Clip], query: String, filter: ClipFilter) -> [Clip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = items
        if let kind = filter.kind {
            candidates = candidates.filter { $0.kind == kind }
        }
        if let pinboardID = filter.pinboardID {
            candidates = candidates.filter { $0.pinboardID == pinboardID }
        }
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter {
            // `prefix(_:)` is O(scanCap); scanning only the bounded prefix keeps each keystroke cheap
            // regardless of clip size. (`localizedCaseInsensitiveContains` bridges the prefix to
            // NSString — a small, capped ≤scanCap copy per item, not the whole clip.)
            $0.text.prefix(scanCap).localizedCaseInsensitiveContains(trimmed) ||
            ($0.title?.localizedCaseInsensitiveContains(trimmed) ?? false) ||
            $0.sourceApp.localizedCaseInsensitiveContains(trimmed) ||
            $0.kind.title.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
