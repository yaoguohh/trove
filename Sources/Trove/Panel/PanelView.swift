import AppKit
import SwiftUI

/// What the panel content can ask its window to do. Each is one operation owned by
/// `PanelController`, shared with its keyboard path.
struct PanelActions {
    let paste: (Clip) -> Void
    let copy: (Clip) -> Void
    let inspect: (Clip) -> Void
    let close: () -> Void
    let reopen: () -> Void
}

struct PanelView: View {
    @ObservedObject var store: ClipStore
    @ObservedObject var model: PanelViewModel
    let actions: PanelActions

    @State private var hoveredID: Clip.ID?
    @State private var suppressHoverScroll = false
    // Last real pointer location (global). Hover only moves the selection when this changes, so a
    // card scrolling under a stationary pointer can't hijack the keyboard selection.
    @State private var lastHoverLocation: CGPoint?
    // Inline title rename: the draft text. `model.renamingItemID` (shared with the controller) marks
    // which card is being edited; focus moves to its editor through `focus` below.
    @State private var renameDraft = ""
    // Single focus authority: exactly one of `.search` / `.rename(id)` is focused at a time, so the
    // search field and a card's rename editor can never cross-talk (atomic mutual exclusion).
    @FocusState private var focus: PanelFocus?

    private static let toolbarSpacing: CGFloat = 14

    private var filteredItems: [Clip] { model.filteredItems }

    var body: some View {
        VStack(spacing: 0) {
            pasteToolbar
            timeline
                .zIndex(2)
        }
        // The content's popIn (Motion.scale + a 4pt rise) is played by `PanelController` on the hosting
        // view's layer, not here: a SwiftUI popIn re-renders this whole view on every frame.
        .frame(minWidth: PanelController.minimumSize.width, minHeight: PanelController.minimumSize.height)
        .background {
            // Theme.Radius.panel, the same radius as the glass mask behind it: the glass tint, an l2
            // hairline and a one-pixel glass-hi along the top (stopping short of the corner arcs).
            GlassTint(opacity: Theme.Glass.windowOpacity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                        .strokeBorder(Theme.Line.l2, lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.Line.glassHi)
                        .frame(height: 1)
                        .padding(.horizontal, Theme.Radius.panel)
                        .padding(.top, 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .environment(\.clipFiles, store.files)
        .onTapGesture {
            // Clicking empty panel chrome re-focuses the search field.
            focus = .search
        }
        .onAppear {
            focus = .search
        }
        .onChange(of: model.showToken) {
            // Every (re)show focuses the search field so printable input filters immediately without
            // losing its first character; navigation/action keys use the controller's window monitor.
            focus = .search
        }
        .onChange(of: model.refocusToken) {
            // Re-claim focus after an in-place churn (e.g. deleting a card) that dropped it, so
            // printable input keeps editing the query without requiring a re-summon.
            focus = .search
        }
        .onChange(of: focus) {
            // Focus leaving a rename editor (clicking elsewhere / Tab) commits that rename.
            if let id = model.renamingItemID, focus != .rename(id) {
                commitRenameByID(id)
            }
        }
    }

    private var pasteToolbar: some View {
        HStack(alignment: .center, spacing: Self.toolbarSpacing) {
            Button {
                model.resetFilters()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: PanelLayout.toolbarHeight, height: PanelLayout.toolbarHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.Text.t2)

            Spacer(minLength: 0)

            HistorySearchField(
                query: $model.query,
                isActive: focus == .search,
                focus: $focus,
                activate: {
                    model.filter.pinboardID = nil
                }
            )
            .frame(height: PanelLayout.toolbarHeight)

            PinboardStrip(store: store, model: model, spacing: Self.toolbarSpacing, itemHeight: PanelLayout.toolbarHeight)

            Spacer(minLength: 0)

            moreActionsMenu
        }
        .padding(.horizontal, PanelLayout.inset)
        .padding(.top, PanelLayout.inset)
    }

    private var moreActionsMenu: some View {
        Menu {
            Picker(selection: $model.filter.kind) {
                Text("All").tag(nil as ClipKind?)
                ForEach(ClipKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(kind as ClipKind?)
                }
            } label: {
                Text("Type")
            }

            Divider()

            Button {
                if ClearHistoryAlert.confirm() {
                    store.clearUnpinned()
                }
            } label: {
                Label("Clear History...", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.Text.t2)
                .frame(width: PanelLayout.toolbarHeight, height: PanelLayout.toolbarHeight)
                .contentShape(Rectangle())
        }
        // The button menu style with a plain button draws the label as laid out here. The borderless
        // style draws its own control: it ignored the label's frame, font and color, and left the
        // glyph 4pt right of its 28pt square.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var timeline: some View {
        Group {
            if filteredItems.isEmpty {
                emptyState
            } else {
                GeometryReader { geometry in
                    let metrics = CardMetrics(containerSize: geometry.size, inset: PanelLayout.inset)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .center, spacing: metrics.spacing) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    ClipCard(
                                        item: item,
                                        index: index,
                                        pinboard: pinboard(for: item),
                                        isSelected: model.selectedID == item.id,
                                        isHovered: hoveredID == item.id,
                                        searchQuery: model.query,
                                        metrics: metrics,
                                        isRenaming: model.renamingItemID == item.id,
                                        renameText: $renameDraft,
                                        onCommitRename: { commitRename(item) },
                                        onCancelRename: { cancelRename() },
                                        renameFocus: $focus,
                                        now: model.shownAt
                                    )
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .overlay {
                                        CardDragSurface(
                                            item: item,
                                            onClick: {
                                                model.selectedID = item.id
                                                actions.paste(item)
                                            },
                                            onDragStart: {
                                                model.selectedID = item.id
                                            },
                                            onSessionBegan: {
                                                // Hide the panel once the drag is live so it
                                                // never blocks a drop target at screen bottom.
                                                actions.close()
                                            },
                                            onDragEnd: { operation in
                                                // Drop accepted by an app → the drag delivered
                                                // the content. Not accepted → bring the panel
                                                // back so the user can retry (no blind paste).
                                                if operation.isEmpty {
                                                    actions.reopen()
                                                }
                                            },
                                            makeDragImage: {
                                                dragImage(for: item, index: index, metrics: metrics)
                                            }
                                        )
                                        // Disable click/drag on the card being renamed so a stray
                                        // body click can't paste mid-edit.
                                        .allowsHitTesting(model.renamingItemID != item.id)
                                    }
                                    // Hover "rename" pencil, layered ABOVE the drag surface so it
                                    // stays clickable (the editor itself lives inside the header).
                                    .overlay(alignment: .topTrailing) {
                                        if hoveredID == item.id, model.renamingItemID == nil {
                                            renamePencil(for: item, metrics: metrics)
                                        }
                                    }
                                    .zIndex(hoveredID == item.id ? 20 : model.selectedID == item.id ? 10 : 0)
                                    // Tern's card entrance/exit: fade + Motion.scale + a 4pt rise, on the
                                    // out curve (driven by the LazyHStack's animation(value:) below).
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: Theme.Motion.scale)).combined(with: .offset(y: 4)),
                                        removal: .opacity.combined(with: .scale(scale: Theme.Motion.scale))
                                    ))
                                    .onContinuousHover(coordinateSpace: .global) { phase in
                                        switch phase {
                                        case .active(let location):
                                            if hoveredID != item.id {
                                                withAnimation(Theme.Motion.out()) {
                                                    hoveredID = item.id
                                                }
                                            }
                                            // Only let hover steal the keyboard selection on a REAL
                                            // pointer move — NOT when a card scrolls/lays out under a
                                            // stationary pointer (that fires hover at the same global
                                            // location), which would snap the selection backwards.
                                            let moved = lastHoverLocation.map {
                                                hypot(location.x - $0.x, location.y - $0.y) > 0.5
                                            } ?? true
                                            if moved, model.selectedID != item.id {
                                                suppressHoverScroll = true
                                                model.selectedID = item.id
                                            }
                                            lastHoverLocation = location
                                        case .ended:
                                            if hoveredID == item.id {
                                                withAnimation(Theme.Motion.out()) {
                                                    hoveredID = nil
                                                }
                                            }
                                        }
                                    }
                                    .contextMenu {
                                        clipMenu(for: item)
                                    }
                                }
                            }
                            .padding(.horizontal, metrics.sidePadding)
                            .padding(.top, metrics.topPadding)
                            .padding(.bottom, metrics.bottomPadding)
                            // Animate the row whenever its membership changes (a new clip, a delete, a
                            // filter): neighbors slide to close the gap and the card transitions play.
                            .animation(Theme.Motion.out(Theme.Motion.Duration.reflow), value: filteredItems.map(\.id))
                        }
                        .scrollClipDisabled()
                        .scrollIndicators(.hidden)
                        .onChange(of: model.selectedID) {
                            // A show re-selects the first card: jump there, don't scroll across the
                            // row from where the last presentation left off.
                            if model.consumeJumpToSelection() {
                                suppressHoverScroll = false
                                if let selectedID = model.selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                                return
                            }
                            // Hover-driven selection changes skip auto-scroll (the hovered card
                            // is already on screen); only keyboard navigation centers the card.
                            if suppressHoverScroll {
                                suppressHoverScroll = false
                                return
                            }
                            if let selectedID = model.selectedID {
                                withAnimation(Theme.Motion.out(Theme.Motion.Duration.slow)) {
                                    proxy.scrollTo(selectedID, anchor: .center)
                                }
                            }
                        }
                        .onChange(of: model.showToken) {
                            // The row stays mounted between shows; even when the selection didn't
                            // change, the user may have scrolled it away last time.
                            if let selectedID = model.selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            // Sized by its frame, which is then the symbol's visible outline: at a font size the frame
            // adds the font's line space above the symbol, and the group sat 2.3pt low.
            Image(systemName: "doc.on.clipboard")
                .resizable()
                .scaledToFit()
                .frame(height: 54)
                .foregroundStyle(Theme.Text.t3)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(Theme.Text.t1)
            Text("Copy something and it will appear in this tray.")
                .foregroundStyle(Theme.Text.t2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popIn(duration: Theme.Motion.Duration.slow, fade: true, nudge: 6)
    }

    @ViewBuilder
    private func clipMenu(for item: Clip) -> some View {
        // Clicking the card / Return pastes; the menu offers copy + organize. Text clips are stored as
        // plain text only, so there is no separate "paste as plain text".
        Button {
            actions.copy(item)
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        // Open the inspector, a full-size content-adaptive window (panel stays open for comparison).
        Button {
            actions.inspect(item)
        } label: {
            Label("Preview", systemImage: "eye.square")
        }

        // Rename inline in the card header (also searchable).
        Button {
            startRename(item)
        } label: {
            Label("Rename", systemImage: "square.and.pencil")
        }

        Divider()

        // Organize.
        Button {
            store.togglePin(item)
        } label: {
            Label(item.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                  systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Menu {
            Button("None") {
                store.move(item, to: nil)
            }
            ForEach(store.pinboards) { pinboard in
                Button(pinboard.name) {
                    store.move(item, to: pinboard)
                }
            }
        } label: {
            Label("Move to Pinboard", systemImage: "tray.full")
        }

        Divider()

        // Group 3 — destructive.
        Button(role: .destructive) {
            model.delete(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Inline title rename

    private func startRename(_ item: Clip) {
        renameDraft = item.title ?? ""
        // Render the editor (renamingItemID drives its visibility), then move the single focus
        // authority onto it. External assignment is more reliable than the cell focusing itself.
        model.renamingItemID = item.id
        focus = .rename(item.id)
    }

    private func commitRename(_ item: Clip) {
        guard model.renamingItemID == item.id else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        store.rename(item, to: name.isEmpty ? nil : name)
        model.renamingItemID = nil
        if focus == .rename(item.id) { focus = .search }
    }

    private func cancelRename() {
        // Clear visibility BEFORE moving focus, so the onChange(focus) blur-commit sees no pending
        // rename and discards instead of saving.
        model.renamingItemID = nil
        focus = .search
    }

    /// Commit the rename for a given id when focus leaves its editor (blur-commit).
    private func commitRenameByID(_ id: Clip.ID) {
        if let item = filteredItems.first(where: { $0.id == id }) {
            commitRename(item)
        } else {
            model.renamingItemID = nil
        }
    }

    /// Hover affordance: a square.and.pencil button in the header (left of the source icon),
    /// vertically centered in the gradient bar.
    private func renamePencil(for item: Clip, metrics: CardMetrics) -> some View {
        Button {
            startRename(item)
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: max(12, metrics.titleSize - 2), weight: .semibold))
                .foregroundStyle(Theme.Text.t2)
                .frame(width: 24, height: 24)
                .background(Theme.Surface.raise, in: Circle())
                .overlay { Circle().strokeBorder(Theme.Line.l2, lineWidth: 1) }
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .help(String(localized: "Rename"))
        .padding(.trailing, metrics.iconSize + 14)
        .padding(.top, max(4, (metrics.headerHeight - 24) / 2))
    }

    /// A 1:1 snapshot of the on-screen card, used as the drag preview so the floating image
    /// matches exactly (gradient header, source icon, body, footer, rounded corners).
    @MainActor
    private func dragImage(for item: Clip, index: Int, metrics: CardMetrics) -> NSImage? {
        let card = ClipCard(
            item: item,
            index: index,
            pinboard: pinboard(for: item),
            isSelected: false,
            isHovered: false,
            searchQuery: model.query,
            metrics: metrics,
            renameFocus: $focus
        )
        .frame(width: metrics.width, height: metrics.height)
        .environment(\.clipFiles, store.files)
        let renderer = ImageRenderer(content: card)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private func pinboard(for item: Clip) -> Pinboard? {
        guard let id = item.pinboardID else { return nil }
        return store.pinboards.first { $0.id == id }
    }
}
