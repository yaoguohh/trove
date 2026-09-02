import SwiftUI

struct ImagePreview: View {
    let item: ClipboardItem

    var body: some View {
        Group {
            if let url = item.imageFileURL, let image = ImageCache.image(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 28, weight: .medium))
                    Text("Image unavailable")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct LinkPreview: View {
    let item: ClipboardItem
    let accent: Color
    let searchQuery: String
    let metrics: CardMetrics

    @State private var metadata: LinkMetadata?

    /// Pure derivation of the hero / route / host strings (see `LinkCardText`). Recomputes when the
    /// async `metadata` lands, which only enriches the hero + favicon — the route line is identical
    /// in both states, so the card never reflows when the title arrives.
    private var cardText: LinkCardText {
        LinkCardText.make(rawURL: item.text, metadata: metadata)
    }

    var body: some View {
        let text = cardText
        VStack(alignment: .leading, spacing: 8) {
            // Site icon + hero: the fetched page title, else the smart path-tail, else the host.
            HStack(alignment: .top, spacing: 8) {
                LinkSiteIcon(metadata: metadata, accent: accent, size: metrics.iconSize * 0.72)
                HighlightedText(text: text.primary, query: searchQuery)
                    .font(.system(size: metrics.titleSize + 1, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // The always-on route line — what tells two same-host links apart. Shown as a full URL
            // (host + path) so it reads as a real link rather than a stray "/path". Head-truncated so
            // the distinguishing tail ("…/issues/1234") stays visible; gets a second line when no title
            // competes for the card's height. Omitted entirely for a root URL (nothing more to show).
            if let route = text.route {
                HighlightedText(text: text.host + route, query: searchQuery)
                    .font(.system(size: metrics.footerSize, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(text.primaryIsTitle ? 1 : 2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                HighlightedText(text: text.host, query: searchQuery)
                    .font(.system(size: metrics.footerSize))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(accent)
                    .frame(height: 5)
                }
        }
        .task(id: item.text) {
            metadata = await LinkMetadataProvider.shared.metadata(for: item.text)
        }
    }
}

struct LinkSiteIcon: View {
    let metadata: LinkMetadata?
    let accent: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let url = metadata?.iconFileURL, let image = ImageCache.image(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.10)
                    .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(accent.opacity(0.16))
                    .overlay {
                        Image(systemName: "link")
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(accent)
                    }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.08), radius: 4, x: 0, y: 2)
    }
}

struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributedText)
    }

    /// Belt-and-suspenders bound on the string an `AttributedString` is built from. Card bodies are
    /// already fed `item.preview` (capped to `displayPreviewCap`), but `HighlightedText` is also used
    /// for link titles/hosts and could be reused, so cap here too. `prefix(_:)` is O(cap) regardless
    /// of the source length, so building the attributed copy can never scan a multi-MB string.
    private static let highlightDefensiveCap = 8_000

    private var attributedText: AttributedString {
        let capped = String(text.prefix(Self.highlightDefensiveCap))
        var attributed = AttributedString(capped)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        let lowerText = capped.lowercased()
        let lowerNeedle = needle.lowercased()
        var searchRange = lowerText.startIndex..<lowerText.endIndex

        while let match = lowerText.range(of: lowerNeedle, range: searchRange) {
            if let start = AttributedString.Index(match.lowerBound, within: attributed),
               let end = AttributedString.Index(match.upperBound, within: attributed) {
                attributed[start..<end].backgroundColor = .yellow.opacity(0.55)
            }

            guard match.upperBound < lowerText.endIndex else { break }
            searchRange = match.upperBound..<lowerText.endIndex
        }

        return attributed
    }
}

struct SourceIcon: View {
    let item: ClipboardItem
    let style: SourceAppStyle
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = SourceAppIconProvider.icon(for: item) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.14), radius: size * 0.13, x: 0, y: size * 0.06)
    }

    private var fallbackIcon: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(style.color.opacity(0.16))
            .overlay {
                if let symbolName = style.symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.48, weight: .bold))
                    .foregroundStyle(style.color)
                } else {
                    Text(style.initials)
                        .font(.system(size: size * 0.30, weight: .heavy))
                        .foregroundStyle(style.color)
                        .minimumScaleFactor(0.70)
                        .lineLimit(1)
                }
            }
    }
}
