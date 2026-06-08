import AppKit
import SwiftUI

/// Rich, native, zero-dependency previews shown ONLY in the full inspect window (never per-card —
/// cards keep the cheap capped `HighlightedText`). Each is a pure display layer over verbatim text.
/// URLs are intentionally NOT rendered here: a single bare URL opens in the default browser instead
/// (see `ClipboardPanelController.showPreview`), so there is no in-app web card.

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

            ScrollView {
                Text(showFormatted ? formatted : raw)
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if isTruncated {
                    // The content itself was lost at the ceiling — paste won't be complete. Be honest
                    // (matches the card's "Truncated" chip) rather than promising full fidelity.
                    Text("This clip was too large and was shortened; pasting will not include the full content.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if bounded.isClipped {
                    Text("Preview shortened for performance; copy or paste delivers the full content.")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(bounded.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(18)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
