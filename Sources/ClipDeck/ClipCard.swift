import SwiftUI

struct ClipCard: View {
    let item: ClipboardItem
    let index: Int
    let pinboard: Pinboard?
    let isSelected: Bool
    let isHovered: Bool
    let searchQuery: String
    let metrics: CardMetrics

    private var sourceStyle: SourceAppStyle {
        SourceAppStyle.resolve(for: item.sourceApp)
    }

    private var accentColor: Color {
        SourceAppIconProvider.accentColor(for: item, fallback: sourceStyle.color)
    }

    private var accentPalette: [Color] {
        SourceAppIconProvider.accentPalette(for: item, fallback: sourceStyle.color)
    }

    var body: some View {
        ClipCardChrome(
            header: {
                ClipCardHeader(
                    item: item,
                    sourceStyle: sourceStyle,
                    accentPalette: accentPalette,
                    metrics: metrics
                )
            },
            content: {
                cardBody
            },
            footer: {
                ClipCardFooter(
                    pinboard: pinboard,
                    characterCount: item.characterCount,
                    index: index,
                    metrics: metrics
                )
            },
            isSelected: isSelected,
            isHovered: isHovered,
            metrics: metrics
        )
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.kind == .image {
                ImagePreview(item: item)
            } else if item.kind == .link {
                LinkPreview(item: item, accent: accentColor, searchQuery: searchQuery, metrics: metrics)
            } else {
                HighlightedText(text: item.preview, query: searchQuery)
                    .font(.system(size: metrics.bodySize, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(contentLineLimit)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(metrics.cornerRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var contentLineLimit: Int {
        let availableHeight = metrics.contentHeight - metrics.cornerRadius * 2
        return max(2, Int(availableHeight / (metrics.bodySize * 1.35)))
    }
}

private struct ClipCardChrome<Header: View, Content: View, Footer: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    let header: Header
    let content: Content
    let footer: Footer
    let isSelected: Bool
    let isHovered: Bool
    let metrics: CardMetrics

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer,
        isSelected: Bool,
        isHovered: Bool,
        metrics: CardMetrics
    ) {
        self.header = header()
        self.content = content()
        self.footer = footer()
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.metrics = metrics
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: metrics.headerHeight)
            content
                .frame(height: metrics.contentHeight)
                .clipped()
            footer
                .frame(height: metrics.footerHeight)
        }
        .frame(width: metrics.width, height: metrics.height)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                .stroke(isSelected ? Color.blue : cardStroke, lineWidth: isSelected ? 4 : 1)
        }
        .shadow(
            color: .black.opacity(isHovered || isSelected ? 0.18 : 0.06),
            radius: isHovered || isSelected ? 16 : 6,
            x: 0,
            y: isHovered || isSelected ? 8 : 4
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.80), value: isHovered)
    }

    private var cardBackground: Color {
        // Fully opaque: the chrome is highly translucent (Dock-style), so a card must completely
        // occlude the blurred desktop beneath it for crisp, readable content. Only the
        // surrounding chrome is glass; the cards carry their own contrast.
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.13, blue: 0.15)
            : Color.white
    }

    private var cardStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }
}

private struct ClipCardHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let item: ClipboardItem
    let sourceStyle: SourceAppStyle
    let accentPalette: [Color]
    let metrics: CardMetrics

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: gradientColors,
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.36))
                        .frame(height: 1)
                }

            HStack(spacing: 6) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: max(10, metrics.titleSize - 3), weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(45))
                }
                Text(item.kind.title)
                    .font(.system(size: max(13, metrics.titleSize - 1), weight: .bold))
                    .foregroundStyle(.primary)
                Text(item.createdAt, style: .relative)
                    .font(.system(size: max(10, metrics.footerSize - 2), weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, metrics.cornerRadius * 0.82)
            .padding(.trailing, metrics.iconSize + 12)
            .padding(.top, 9)

            SourceIcon(item: item, style: sourceStyle, size: metrics.iconSize)
                .padding(.trailing, 8)
                // Vertically center the source icon within the gradient header (was top-aligned).
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(height: metrics.headerHeight)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: metrics.cornerRadius, topTrailingRadius: metrics.cornerRadius))
    }

    private var gradientColors: [Color] {
        let topOpacity = colorScheme == .dark ? 0.26 : 0.16
        let midOpacity = colorScheme == .dark ? 0.12 : 0.07
        let tailOpacity = colorScheme == .dark ? 0.03 : 0.00
        let colors = Array(accentPalette.prefix(3))

        switch colors.count {
        case 0:
            return [Color.clear]
        case 1:
            return [
                colors[0].opacity(topOpacity),
                colors[0].opacity(midOpacity),
                colors[0].opacity(tailOpacity)
            ]
        case 2:
            return [
                colors[0].opacity(topOpacity),
                colors[1].opacity(midOpacity),
                colors[1].opacity(tailOpacity)
            ]
        default:
            return [
                colors[0].opacity(topOpacity),
                colors[1].opacity(midOpacity),
                colors[2].opacity(tailOpacity)
            ]
        }
    }
}

private struct ClipCardFooter: View {
    @Environment(\.colorScheme) private var colorScheme

    let pinboard: Pinboard?
    let characterCount: Int
    let index: Int
    let metrics: CardMetrics

    var body: some View {
        HStack {
            if let pinboard {
                Text(pinboard.name)
                    .footerChip(background: colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.07), metrics: metrics)
            }
            Spacer()
            Text("\(characterCount) characters")
                .font(.system(size: metrics.footerSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
            Text("\(index + 1)")
                .font(.system(size: metrics.footerSize, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.cornerRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private extension View {
    func footerChip(background: Color, metrics: CardMetrics) -> some View {
        self
            .font(.system(size: metrics.footerSize, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.80)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }
}
