import AppKit
import SwiftUI

/// Rich, native, zero-dependency previews shown ONLY in the full inspector (never per-card —
/// cards keep the cheap capped `HighlightedText`). Each is a pure display layer over verbatim text.
/// URLs are intentionally NOT rendered here: a single bare URL opens in the default browser instead
/// (see `PanelController.showInspector`), so there is no in-app web card.

/// A read-only, natively selectable text view — an `NSTextView` in an `NSScrollView`. SwiftUI `Text`
/// + `.textSelection(.enabled)` selects awkwardly inside a `ScrollView`; a real `NSTextView` gives
/// reliable drag-select, ⌘C/⌘A, and the right-click Copy / Select All menu, with native scrolling
/// (so the SwiftUI `ScrollView` is dropped where this is used). Read-only and plain (non-rich) so it
/// can't be edited — the clip's verbatim copy/paste fidelity lives elsewhere.
struct SelectableText: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 13)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        if let textView = scroll.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.drawsBackground = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.textContainerInset = NSSize(width: 6, height: 10)
            // Wrap long lines to the view width instead of scrolling horizontally.
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.font = font
            textView.textColor = NSColor(Theme.Text.t1)
            textView.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // Only reset the string when it actually changed (e.g. the JSON Formatted/Raw toggle), so a
        // SwiftUI re-render doesn't clobber the user's in-progress selection.
        if textView.string != text { textView.string = text }
        textView.font = font
    }
}

/// A JSON clip pretty-printed (sorted keys, indented) in a monospaced, selectable view, with a
/// Formatted / Raw Text toggle. The pretty string is precomputed by `InspectorRenderer.prettyJSON`
/// (native `JSONSerialization`, validity- and size-gated).
struct JSONInspectorView: View {
    let formatted: String
    let raw: String

    @State private var showFormatted = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $showFormatted) {
                Text("Formatted").tag(true)
                Text("Raw Text").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.horizontal, 18)
            .padding(.vertical, 10)

            Divider()

            SelectableText(
                text: showFormatted ? formatted : raw,
                font: .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Surface.coal)
        }
    }
}

/// Plain-text fallback: the full clip (up to the inspector's layout guard), with a notice when
/// clipped. The bounded body is resolved off the SwiftUI body (in `InspectorController.show`) and
/// passed in, so re-renders never re-read the sidecar. Selectable.
struct BoundedPlainText: View {
    let bounded: (text: String, isClipped: Bool)
    /// Whether the clip hit the ultimate ceiling (its content was hard-truncated at ingestion).
    let isTruncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isTruncated {
                // The content itself was lost at the ceiling — paste won't be complete. Be honest
                // (matches the card's "Truncated" chip) rather than promising full fidelity.
                notice(String(localized: "This clip was too large and was shortened; pasting will not include the full content."))
            } else if bounded.isClipped {
                notice(String(localized: "Preview shortened for performance; copy or paste delivers the full content."))
            }
            SelectableText(text: bounded.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Surface.coal)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.Text.t2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)
    }
}

struct InspectorView: View {
    let item: Clip
    let image: NSImage?
    /// Bounded plain-text body, resolved once in `show()` (off the body). Nil for image items.
    let plainBody: (text: String, isClipped: Bool)?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Surface.coal)
        } else if item.kind == .image {
            // An image item whose file went missing — show a clear placeholder, not blank.
            ImageUnavailableView(symbolSize: 40, textSize: 14)
                .background(Theme.Surface.coal)
        } else {
            // Detection runs on the bounded inline `text` (cheap); each branch is a pure display
            // layer. Rich previews live ONLY here, never per-card.
            switch InspectorRenderer.detect(item.text, kind: item.kind) {
            case .json(let pretty):
                JSONInspectorView(formatted: pretty, raw: item.text)
            case .url, .plain:
                // A single URL opens in the default browser before this window is ever shown (see
                // PanelController.showInspector); the `.url` case here is a defensive fallback
                // that renders the raw URL as plain text rather than a native web card.
                BoundedPlainText(bounded: plainBody ?? (item.text, false), isTruncated: item.isTruncated)
            }
        }
    }

}

/// The Keep-on-Top toggle hosted in the inspector's titlebar (trailing accessory). Owns its
/// pinned state and calls back to flip the window's level/collectionBehavior.
struct PinTitlebarButton: View {
    let apply: (Bool) -> Void
    @State private var isPinned = false

    var body: some View {
        Button {
            isPinned.toggle()
            apply(isPinned)
        } label: {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPinned ? Theme.accent : Theme.Text.t3)
                .frame(width: 32, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(isPinned ? String(localized: "Unpin") : String(localized: "Keep on Top"))
    }
}
