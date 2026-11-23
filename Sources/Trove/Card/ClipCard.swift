import SwiftUI

/// A clip as a card: one meta row along the top (source icon and name at the left; pin, pinboard,
/// truncation and the time at the right), then the content. The card is a light pane of the panel's glass, and the
/// source app's color glows from its top-left corner instead of filling a header band. See
/// docs/adr/0019-card-meta-row.md.
struct ClipCard: View {
    let item: Clip
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
    /// What the meta row's "5 min ago" is measured against: the moment the panel was shown.
    var now: Date = .now

    private var sourceStyle: SourceAppStyle {
        SourceAppStyle.resolve(for: item.sourceApp)
    }

    private var accentColor: Color {
        SourceAppIconProvider.accentColor(for: item, fallback: sourceStyle.color)
    }

    /// Selection = one step up the glass + a 1.5pt accent hairline + a soft 18% outer ring (Tern's focus
    /// ring), instead of a thick system-blue stroke.
    private static let ringWidth: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        VStack(alignment: .leading, spacing: metrics.metaSpace) {
            ClipCardMetaRow(
                item: item,
                pinboard: pinboard,
                sourceStyle: sourceStyle,
                metrics: metrics,
                now: now,
                isRenaming: isRenaming,
                renameText: renameText,
                renameFocus: renameFocus,
                onCommit: onCommitRename,
                onCancel: onCancelRename
            )
            .frame(height: metrics.iconSize)
            cardBody
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: metrics.contentHeight, alignment: .topLeading)
                .clipped()
        }
        .padding(.horizontal, metrics.contentInset)
        .padding(.top, metrics.metaSpace)
        .padding(.bottom, metrics.contentInset)
        .frame(width: metrics.width, height: metrics.height, alignment: .topLeading)
        // A pane of the glass, not an opaque block: no drop shadow either, since a shadow of a
        // see-through card would fall from its text.
        .background {
            ZStack(alignment: .topLeading) {
                shape.fill(isSelected || isHovered ? Theme.Surface.glassCardRaised : Theme.Surface.glassCard)
                RadialGradient(colors: [accentColor.opacity(Theme.Tint.sourceGlow), .clear], center: .topLeading, startRadius: 0, endRadius: metrics.glowRadius)
                // glass-hi: the one-pixel top highlight every raised surface gets.
                Rectangle().fill(Theme.Line.glassHi).frame(height: 1)
            }
        }
        .clipShape(shape)
        .overlay {
            // Hairline (l2) at rest; the accent hairline when selected.
            shape.strokeBorder(isSelected ? Theme.accent : Theme.Line.l2, lineWidth: isSelected ? 1.5 : 1)
        }
        .overlay {
            // Outer ring sits fully outside the card edge: the overlay is inflated by half the ring
            // width so a centered stroke spans exactly [edge, edge + ringWidth].
            RoundedRectangle(cornerRadius: metrics.cornerRadius + Self.ringWidth / 2, style: .continuous)
                .stroke(Theme.Accent.ring, lineWidth: Self.ringWidth)
                .padding(-Self.ringWidth / 2)
                .opacity(isSelected ? 1 : 0)
        }
        .animation(Theme.Motion.out(), value: isHovered)
        .animation(Theme.Motion.out(), value: isSelected)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    /// What VoiceOver reads for the card: name/kind, source app, then the content excerpt.
    private var accessibilityDescription: String {
        let excerpt = item.kind == .image ? "" : String(item.excerpt.prefix(200))
        let head = "\(item.name), \(sourceStyle.displayName)"
        return excerpt.isEmpty ? head : "\(head): \(excerpt)"
    }

    @ViewBuilder
    private var cardBody: some View {
        if item.kind == .image {
            ImageCardBody(item: item)
        } else if item.kind == .link {
            LinkCardBody(item: item, accent: accentColor, searchQuery: searchQuery, metrics: metrics)
        } else {
            HighlightedText(text: item.excerpt, query: searchQuery)
                .font(.system(size: metrics.bodySize, weight: .medium))
                .foregroundStyle(Theme.Text.t1)
                .lineLimit(max(2, Int(metrics.contentHeight / (metrics.bodySize * 1.35))))
        }
    }
}

/// The card's one line of metadata: what it is at the left, when at the right. The name truncates first;
/// the markers and the time keep their width.
private struct ClipCardMetaRow: View {
    let item: Clip
    let pinboard: Pinboard?
    let sourceStyle: SourceAppStyle
    let metrics: CardMetrics
    let now: Date
    let isRenaming: Bool
    let renameText: Binding<String>
    let renameFocus: FocusState<PanelFocus?>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// "5 min ago" / "5分钟前" in the user's locale.
    @MainActor private static let relativeTime: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .short
        return formatter
    }()

    private var nameFont: NSFont { .systemFont(ofSize: metrics.nameSize, weight: .semibold) }
    // The time is t2, not t3: on a glass card over a light desktop, t3 drops to 1.5:1.
    private var detailFont: NSFont { .systemFont(ofSize: metrics.detailSize, weight: .medium) }

    /// Name and time share one baseline, as a notification's app name and time do; the icon and the
    /// markers center on the name's capitals. Centered on a taller icon instead, the smaller time hung
    /// below the row's top and read as low.
    var body: some View {
        // Puts a non-text item's center on the middle of the name's capitals.
        let lift = nameFont.capHeight / 2
        let onCapitals: @Sendable (ViewDimensions) -> CGFloat = { $0[VerticalAlignment.center] + lift }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            SourceIcon(item: item, style: sourceStyle, size: metrics.iconSize)
                .alignmentGuide(.firstTextBaseline, computeValue: onCapitals)
            if isRenaming {
                // Borderless, in-place editor: same font as the name, no separate box. Focus is driven by
                // the shared PanelFocus authority (set to .rename(id) by startRename), not a local
                // @FocusState — so it focuses reliably and never cross-talks.
                TextField("", text: renameText, prompt: Text(item.kind.title))
                    .textFieldStyle(.plain)
                    .font(Font(nameFont))
                    .foregroundStyle(Theme.Text.t1)
                    .focused(renameFocus, equals: .rename(item.id))
                    .onSubmit(onCommit)
                    .onExitCommand(perform: onCancel) // Esc cancels
            } else {
                // A custom name (Rename) replaces the kind label; the kind is still conveyed by the
                // content itself.
                Text(item.name)
                    .font(Font(nameFont))
                    .foregroundStyle(Theme.Text.t1)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: metrics.detailSize - 1, weight: .semibold))
                    .foregroundStyle(Theme.Text.t2)
                    .rotationEffect(.degrees(45))
                    .alignmentGuide(.firstTextBaseline, computeValue: onCapitals)
            }
            if let pinboard {
                Circle()
                    .fill(PinboardColor.color(named: pinboard.colorName))
                    .frame(width: 7, height: 7)
                    .help(pinboard.name)
                    .alignmentGuide(.firstTextBaseline, computeValue: onCapitals)
            }
            if item.isTruncated {
                // Only the rare ceiling-hit clip: honest signal that paste won't include the tail.
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: metrics.detailSize - 1, weight: .semibold))
                    .foregroundStyle(Theme.Semantic.warn)
                    .help(String(localized: "This clip was too large and was shortened; pasting will not include the full content."))
                    .alignmentGuide(.firstTextBaseline, computeValue: onCapitals)
            }
            // Fixed at the time the panel was shown. A live `Text(_, style: .relative)` ticks every
            // second, and each tick re-lays out the whole panel.
            Text(verbatim: Self.relativeTime.localizedString(for: item.createdAt, relativeTo: now))
                .font(Font(detailFont))
                .foregroundStyle(Theme.Text.t2)
                .lineLimit(1)
                .fixedSize()
        }
    }
}
