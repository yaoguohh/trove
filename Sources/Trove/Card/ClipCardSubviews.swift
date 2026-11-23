import SwiftUI

struct ImageCardBody: View {
    let item: Clip
    @Environment(\.clipFiles) private var files

    var body: some View {
        Group {
            // The thumbnail, never the original: a card is ~300pt wide, and decoding every screenshot
            // at full size would keep tens of MB of bitmaps resident while the panel is hidden.
            if let image = ImageCache.thumbnail(for: item, in: files) {
                // Rounded and outlined at the picture's fitted size, then placed at the top-left like
                // text. Framed first, the outline drew around the whole body with the picture floating
                // in the middle of it.
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
                    // A hairline keeps a white-background image from reading as a hole in the card.
                    .overlay { RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous).strokeBorder(Theme.Line.l2, lineWidth: 1) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ImageUnavailableView(symbolSize: 28, textSize: 13)
            }
        }
    }
}

struct LinkCardBody: View {
    let item: Clip
    let accent: Color
    let searchQuery: String
    let metrics: CardMetrics

    @State private var metadata: LinkMetadata?
    /// True once the metadata lookup has answered (with or without a title), so the shimmer that
    /// marks the hero as "still loading" stops either way.
    @State private var resolved = false

    /// Pure derivation of the hero / route / host strings (see `LinkCardText`). Recomputes when the
    /// async `metadata` lands, which only enriches the hero + favicon — the route line is identical
    /// in both states, so the card never reflows when the title arrives.
    private var cardText: LinkCardText {
        LinkCardText.make(rawURL: item.text, metadata: metadata)
    }

    private var heroFont: NSFont {
        .systemFont(ofSize: metrics.titleSize, weight: .semibold)
    }

    var body: some View {
        let text = cardText
        VStack(alignment: .leading, spacing: 8) {
            // Site icon + hero: the fetched page title, else the smart path-tail, else the host. The
            // icon centers on the title's first line, at half its cap height. Top alignment left that
            // line 4pt above the icon's center; centering on the whole title would move the icon with
            // the number of lines.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LinkSiteIcon(metadata: metadata, accent: accent, size: metrics.siteIconSize)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + heroFont.capHeight / 2 }
                HighlightedText(text: text.primary, query: searchQuery)
                    .font(Font(heroFont))
                    .foregroundStyle(Theme.Text.t1)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Tern's working-state shimmer while the page title is still on its way; the
                    // fetched title then cross-fades in instead of snapping.
                    .shimmer(!resolved && LinkMetadataProvider.isFetchingEnabled)
                    .contentTransition(.opacity)
                    .animation(Theme.Motion.ease, value: metadata)
            }

            // The always-on route line — what tells two same-host links apart. Shown as a full URL
            // (host + path) so it reads as a real link rather than a stray "/path". Head-truncated so
            // the distinguishing tail ("…/issues/1234") stays visible; gets a second line when no title
            // competes for the card's height. Omitted entirely for a root URL (nothing more to show).
            if let route = text.route {
                HighlightedText(text: text.host + route, query: searchQuery)
                    .font(.system(size: metrics.captionSize, design: .monospaced))
                    .foregroundStyle(Theme.Text.t2)
                    .lineLimit(text.primaryIsTitle ? 1 : 2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.top, 1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                HighlightedText(text: text.host, query: searchQuery)
                    .font(.system(size: metrics.captionSize))
                    .foregroundStyle(Theme.Text.t3)
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
            resolved = true
        }
    }
}

struct LinkSiteIcon: View {
    let metadata: LinkMetadata?
    let accent: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let url = metadata?.iconFileURL, let image = ImageCache.icon(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.10)
                    .background(Theme.Surface.faviconPlate, in: RoundedRectangle(cornerRadius: Theme.Radius.icon(size: size), style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.icon(size: size), style: .continuous)
                    .fill(accent.opacity(Theme.Tint.fill))
                    .overlay {
                        Image(systemName: "link")
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(accent)
                    }
            }
        }
        .frame(width: size, height: size)
        .shadow(Theme.Shadow.badge(size: size))
    }
}

struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(attributedText)
    }

    private var attributedText: AttributedString {
        // Card bodies are already `item.excerpt` (capped), but link titles and hosts arrive here too;
        // the same cap keeps building the attributed copy O(cap) for any input.
        let capped = String(text.prefix(Clip.excerptCap))
        var attributed = AttributedString(capped)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return attributed }

        let lowerText = capped.lowercased()
        let lowerNeedle = needle.lowercased()
        var searchRange = lowerText.startIndex..<lowerText.endIndex

        while let match = lowerText.range(of: lowerNeedle, range: searchRange) {
            if let start = AttributedString.Index(match.lowerBound, within: attributed),
               let end = AttributedString.Index(match.upperBound, within: attributed) {
                attributed[start..<end].backgroundColor = Theme.Accent.highlight
            }

            guard match.upperBound < lowerText.endIndex else { break }
            searchRange = match.upperBound..<lowerText.endIndex
        }

        return attributed
    }
}

struct SourceIcon: View {
    let item: Clip
    let style: SourceAppStyle
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = SourceAppIconProvider.icon(for: item) {
                AppIconImage(image: icon, size: size)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .shadow(Theme.Shadow.badge(size: size))
    }

    private var fallbackIcon: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.icon(size: size), style: .continuous)
            .fill(style.color.opacity(Theme.Tint.fill))
            .overlay {
                Text(style.initials)
                    .font(.system(size: size * 0.30, weight: .heavy))
                    .foregroundStyle(style.color)
                    .minimumScaleFactor(0.70)
                    .lineLimit(1)
            }
    }
}
