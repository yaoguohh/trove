import SwiftUI

struct ClipCard: View {
    let item: ClipboardItem
    let index: Int
    let pinboard: Pinboard?
    let isSelected: Bool
    let isHovered: Bool
    let searchQuery: String
    let metrics: CardMetrics
    // Inline title rename. isRenaming + the callbacks are defaulted so off-screen renders (the drag
    // image) can omit them; `renameFocus` is required — a FocusState.Binding can't have a default, and
    // every live call site (the timeline ForEach and the drag-image render) provides $focus.
    var isRenaming: Bool = false
    var renameText: Binding<String> = .constant("")
    var onCommitRename: () -> Void = {}
    var onCancelRename: () -> Void = {}
    /// The shared single focus authority; this card's editor is `.rename(item.id)`.
    var renameFocus: FocusState<PanelFocus?>.Binding

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
                    metrics: metrics,
                    isRenaming: isRenaming,
                    renameText: renameText,
                    renameFocus: renameFocus,
                    onCommit: onCommitRename,
                    onCancel: onCancelRename
                )
            },
            content: {
                cardBody
            },
            footer: {
                ClipCardFooter(
                    createdAt: item.createdAt,
                    pinboard: pinboard,
                    characterCount: item.characterCount,
                    isTruncated: item.isTruncated,
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
                    .foregroundStyle(Theme.Text.t1)
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

    /// Selection = one step up the surface ladder + a 1.5pt accent hairline + a soft 18% outer ring
    /// (Tern's focus ring), instead of a thick system-blue stroke. (Computed: a generic type can't
    /// hold a static stored property.)
    private var ringWidth: CGFloat { 4 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
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
        // Opaque: the chrome is highly translucent (Dock-style), so a card must completely occlude the
        // blurred desktop beneath it for crisp, readable content. Only the surrounding chrome is glass.
        .background(isSelected ? Theme.Surface.raise : Theme.Surface.card, in: shape)
        .clipShape(shape)
        .overlay {
            // Hairline (l2) at rest; the accent hairline when selected.
            shape.strokeBorder(isSelected ? Theme.accent : Theme.Line.l2, lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay {
            // Outer ring sits fully outside the card edge: the overlay is inflated by half the ring
            // width so a centered stroke spans exactly [edge, edge + ringWidth].
            RoundedRectangle(cornerRadius: metrics.cornerRadius + ringWidth / 2, style: .continuous)
                .stroke(Theme.Accent.ring, lineWidth: ringWidth)
                .padding(-ringWidth / 2)
                .opacity(isSelected ? 1 : 0)
        }
        .shadow(
            color: .black.opacity(isHovered || isSelected ? 0.26 : 0.14),
            radius: isHovered || isSelected ? 18 : 8,
            x: 0,
            y: isHovered || isSelected ? 8 : 4
        )
        .animation(Theme.Motion.out(0.2), value: isHovered)
        .animation(Theme.Motion.out(0.2), value: isSelected)
    }
}

private struct ClipCardHeader: View {
    let item: ClipboardItem
    let sourceStyle: SourceAppStyle
    let accentPalette: [Color]
    let metrics: CardMetrics
    let isRenaming: Bool
    let renameText: Binding<String>
    let renameFocus: FocusState<PanelFocus?>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    private var titleFont: Font { .system(size: max(13, metrics.titleSize - 1), weight: .bold) }

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
                    // glass-hi: the one-pixel top highlight every raised surface gets.
                    Rectangle()
                        .fill(Theme.Line.glassHi)
                        .frame(height: 1)
                }

            HStack(spacing: 6) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: max(10, metrics.titleSize - 3), weight: .semibold))
                        .foregroundStyle(Theme.Text.t2)
                        .rotationEffect(.degrees(45))
                }
                if isRenaming {
                    // Borderless, in-place editor: same font as the title, no separate box. Focus is
                    // driven by the shared PanelFocus authority (set to .rename(id) by startRename),
                    // not a local @FocusState — so it focuses reliably and never cross-talks.
                    TextField("", text: renameText, prompt: Text(item.kind.title))
                        .textFieldStyle(.plain)
                        .font(titleFont)
                        .foregroundStyle(Theme.Text.t1)
                        .focused(renameFocus, equals: .rename(item.id))
                        .onSubmit(onCommit)
                        .onExitCommand(perform: onCancel) // Esc cancels
                } else {
                    // A custom name (Rename) replaces the kind label; the kind is still conveyed by
                    // the source icon. Untitled clips fall back to the kind ("Text", …).
                    Text(item.title ?? item.kind.title)
                        .font(titleFont)
                        .foregroundStyle(Theme.Text.t1)
                }
            }
            .lineLimit(1)
            // Fill the header height with leading alignment → title/editor sit vertically centered.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, metrics.cornerRadius * 0.82)
            .padding(.trailing, metrics.iconSize + 12)

            SourceIcon(item: item, style: sourceStyle, size: metrics.iconSize)
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        }
        .frame(height: metrics.headerHeight)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: metrics.cornerRadius, topTrailingRadius: metrics.cornerRadius))
    }

    /// The source app's own hues, kept as Trove's one multi-hue element (it identifies the card's
    /// origin at a glance) but calmed from 26/12/3% to 18/8/0% so the ember accent stays in charge.
    private var gradientColors: [Color] {
        let topOpacity = 0.18
        let midOpacity = 0.08
        let tailOpacity = 0.0
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
    let createdAt: Date
    let pinboard: Pinboard?
    let characterCount: Int
    let isTruncated: Bool
    let index: Int
    let metrics: CardMetrics

    var body: some View {
        HStack(spacing: 8) {
            // Relative time lives at the bottom-left now (moved out of the header).
            Text(createdAt, style: .relative)
                .font(.system(size: metrics.footerSize, weight: .medium))
                .foregroundStyle(Theme.Text.t3)
                .lineLimit(1)
            if let pinboard {
                Text(pinboard.name)
                    .footerChip(background: Theme.Line.l1, foreground: Theme.Text.t2, metrics: metrics)
            }
            if isTruncated {
                // Only the rare ceiling-hit clip: honest signal that paste won't include the tail.
                Text("Truncated")
                    .footerChip(background: Theme.Semantic.warn.opacity(0.18), foreground: Theme.Semantic.warn, metrics: metrics)
                    .help(String(localized: "This clip was too large and was shortened; pasting will not include the full content."))
            }
            Spacer()
            Text("\(characterCount) characters")
                .font(.system(size: metrics.footerSize, weight: .medium))
                .foregroundStyle(Theme.Text.t3)
                .lineLimit(1)
                .minimumScaleFactor(0.80)
            Text("\(index + 1)")
                .font(.system(size: metrics.footerSize, weight: .medium))
                .foregroundStyle(Theme.Text.t3)
                .lineLimit(1)
        }
        .padding(.horizontal, metrics.cornerRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private extension View {
    /// A footer pill: l1 fill with an l2 hairline (never a border), text one tier up from the footer.
    func footerChip(background: Color, foreground: Color, metrics: CardMetrics) -> some View {
        self
            .font(.system(size: metrics.footerSize, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.80)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.Line.l2, lineWidth: 1) }
    }
}
