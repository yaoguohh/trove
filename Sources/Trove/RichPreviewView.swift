import AppKit
import SwiftUI

/// Rich, native, zero-dependency previews shown ONLY in the full inspect window (never per-card —
/// cards keep the cheap capped `HighlightedText`). Each is a pure display layer over verbatim text.
/// URLs are intentionally NOT rendered here: a single bare URL opens in the default browser instead
/// (see `ClipboardPanelController.showPreview`), so there is no in-app web card.

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
/// Formatted / Raw Text toggle. The pretty string is precomputed by `RichPreviewRenderer.prettyJSON`
/// (native `JSONSerialization`, validity- and size-gated).
struct JSONPreviewView: View {
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
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}

/// Plain-text fallback: the full clip (up to the inspect window's layout guard), with a notice when
/// clipped. The bounded body is resolved off the SwiftUI body (in `PreviewWindowController.show`) and
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
                notice("This clip was too large and was shortened; pasting will not include the full content.")
            } else if bounded.isClipped {
                notice("Preview shortened for performance; copy or paste delivers the full content.")
            }
            SelectableText(text: bounded.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func notice(_ key: String.LocalizationValue) -> some View {
        Text(String(localized: key))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 14)
    }
}
