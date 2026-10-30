import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    let monitor: ClipboardMonitor
    @ObservedObject var model: PanelViewModel
    let close: () -> Void
    let reopen: () -> Void
    let preview: (ClipboardItem) -> Void

    @State private var hoveredID: ClipboardItem.ID?
    @State private var suppressHoverScroll = false
    // Last real pointer location (global). Hover only moves the selection when this changes, so a
    // card scrolling under a stationary pointer can't hijack the keyboard selection.
    @State private var lastHoverLocation: CGPoint?
    // Inline title rename: the draft text. `model.renamingItemID` (shared with the controller) marks
    // which card is being edited; the in-header editor (ClipCardHeader) owns its own focus.
    @State private var renameDraft = ""
    // Single focus authority: exactly one of `.search` / `.rename(id)` is focused at a time, so the
    // search field and a card's rename editor can never cross-talk (atomic mutual exclusion).
    @FocusState private var focus: PanelFocus?

    private static let toolbarSpacing: CGFloat = 14
    // Shared height for every toolbar item so they share one vertical center / equal top margin.
    private static let toolbarItemHeight: CGFloat = 36

    private var filteredItems: [ClipboardItem] { model.filteredItems }

    var body: some View {
        VStack(spacing: 0) {
            pasteToolbar
                .zIndex(0)
            timeline
                .zIndex(2)
        }
        // Tern's popIn on the CONTENT only (scale 0.97 + a 4pt rise): the glass behind it is an AppKit
        // behind-window blur that must never be transformed per frame, so the window just fades in
        // (ClipboardPanelController.show) while the content arrives on top of it.
        .popIn(trigger: model.showToken, duration: 0.18, nudge: 4)
        .frame(minWidth: 720, minHeight: 240)
        .background {
            // 16pt corners must match the glass mask in ClipboardPanelController.cornerRadius.
            // No fill tint: the chrome is the material alone plus an l2 hairline and a one-pixel
            // glass-hi along the top (stopping short of the corner arcs).
            RoundedRectangle(cornerRadius: ClipboardPanelController.cornerRadius, style: .continuous)
                .fill(panelOverlay)
                .overlay {
                    RoundedRectangle(cornerRadius: ClipboardPanelController.cornerRadius, style: .continuous)
                        .strokeBorder(Theme.Line.l2, lineWidth: 1)
                }
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.Line.glassHi)
                        .frame(height: 1)
                        .padding(.horizontal, ClipboardPanelController.cornerRadius)
                        .padding(.top, 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: ClipboardPanelController.cornerRadius, style: .continuous))
        .onTapGesture {
            // Clicking empty panel chrome re-focuses the search field.
            focus = .search
        }
        .onAppear {
            model.selectFirst()
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
        .onChange(of: model.query) {
            model.selectFirst()
        }
        .onChange(of: model.filter) {
            model.selectFirst()
        }
    }

    private var panelOverlay: Color {
        // No tint over the glass: the chrome's translucency is the material alone, for maximum
        // Dock-like transparency.
        Color.clear
    }

    private var pasteToolbar: some View {
        HStack(alignment: .center, spacing: Self.toolbarSpacing) {
            Button {
                model.filter = ClipboardSearchFilter()
                model.query = ""
                model.selectFirst()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: Self.toolbarItemHeight)
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
                    model.filter.scope = .history
                    model.filter.pinboardID = nil
                }
            )
            // Uniform 36pt height across all toolbar items so they share one vertical center and
            // an equal top margin (the search field was taller than the icon buttons before).
            .frame(height: Self.toolbarItemHeight)

            PinboardStrip(store: store, model: model, spacing: Self.toolbarSpacing, itemHeight: Self.toolbarItemHeight)

            Spacer(minLength: 0)

            moreActionsMenu
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var moreActionsMenu: some View {
        Menu {
            Picker(selection: $model.filter.kind) {
                Text("All").tag(nil as ClipboardKind?)
                ForEach(ClipboardKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(kind as ClipboardKind?)
                }
            } label: {
                Text("Type")
            }

            Divider()

            Button {
                store.clearUnpinned()
            } label: {
                Label("Clear History", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.Text.t2)
                .frame(width: 36, height: Self.toolbarItemHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var timeline: some View {
        Group {
            if filteredItems.isEmpty {
                emptyState
            } else {
                GeometryReader { geometry in
                    let metrics = CardMetrics(containerSize: geometry.size)
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
                                        renameFocus: $focus
                                    )
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .overlay {
                                        CardDragSurface(
                                            item: item,
                                            onClick: {
                                                model.selectedID = item.id
                                                paste(item)
                                            },
                                            onDragStart: {
                                                model.selectedID = item.id
                                            },
                                            onSessionBegan: {
                                                // Hide the panel once the drag is live so it
                                                // never blocks a drop target at screen bottom.
                                                close()
                                            },
                                            onDragEnd: { operation in
                                                // Drop accepted by an app → the drag delivered
                                                // the content. Not accepted → bring the panel
                                                // back so the user can retry (no blind paste).
                                                if operation.isEmpty {
                                                    reopen()
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
                                    // Tern's card entrance/exit: fade + scale 0.97 + a 4pt rise, on the
                                    // out curve (driven by the LazyHStack's animation(value:) below).
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .scale(scale: 0.97)).combined(with: .offset(y: 4)),
                                        removal: .opacity.combined(with: .scale(scale: 0.97))
                                    ))
                                    .onContinuousHover(coordinateSpace: .global) { phase in
                                        switch phase {
                                        case .active(let location):
                                            if hoveredID != item.id {
                                                withAnimation(Theme.Motion.out(0.2)) {
                                                    hoveredID = item.id
                                                }
                                            }
                                            // Only let hover steal the keyboard selection on a REAL
                                            // pointer move — NOT when a card scrolls/lays out under a
                                            // stationary pointer (that fires hover at the same global
                                            // location), which used to snap the selection backwards.
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
                                                withAnimation(Theme.Motion.out(0.2)) {
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
                            .animation(Theme.Motion.out(0.22), value: filteredItems.map(\.id))
                        }
                        .scrollClipDisabled()
                        .scrollIndicators(.hidden)
                        .onChange(of: model.selectedID) {
                            // Hover-driven selection changes skip auto-scroll (the hovered card
                            // is already on screen); only keyboard navigation centers the card.
                            if suppressHoverScroll {
                                suppressHoverScroll = false
                                return
                            }
                            if let selectedID = model.selectedID {
                                withAnimation(Theme.Motion.out(0.3)) {
                                    proxy.scrollTo(selectedID, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 44))
                .foregroundStyle(Theme.Text.t3)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(Theme.Text.t1)
            Text("Copy something and it will appear in this tray.")
                .foregroundStyle(Theme.Text.t2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .popIn(duration: 0.32, fade: true, nudge: 6)
    }

    @ViewBuilder
    private func clipMenu(for item: ClipboardItem) -> some View {
        // Clicking the card / Return pastes. Items are stored as plain text only, so a
        // "plain text" variant would be identical — the menu just offers copy + organize.
        Button {
            monitor.copy(item)
            close()
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }

        // Open a full-size, content-adaptive preview window (panel stays open for comparison).
        Button {
            preview(item)
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
            store.delete(item)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func paste(_ item: ClipboardItem) {
        close()
        monitor.copyAndPaste(item)
    }

    // MARK: - Inline title rename

    private func startRename(_ item: ClipboardItem) {
        renameDraft = item.title ?? ""
        // Render the editor (renamingItemID drives its visibility), then move the single focus
        // authority onto it. External assignment is more reliable than the cell focusing itself.
        model.renamingItemID = item.id
        focus = .rename(item.id)
    }

    private func commitRename(_ item: ClipboardItem) {
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
    private func commitRenameByID(_ id: ClipboardItem.ID) {
        if let item = filteredItems.first(where: { $0.id == id }) {
            commitRename(item)
        } else {
            model.renamingItemID = nil
        }
    }

    /// Hover affordance: a square.and.pencil button in the header (left of the source icon),
    /// vertically centered in the gradient bar.
    private func renamePencil(for item: ClipboardItem, metrics: CardMetrics) -> some View {
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
    private func dragImage(for item: ClipboardItem, index: Int, metrics: CardMetrics) -> NSImage? {
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
        let renderer = ImageRenderer(content: card)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    private func pinboard(for item: ClipboardItem) -> Pinboard? {
        guard let id = item.pinboardID else { return nil }
        return store.pinboards.first { $0.id == id }
    }
}
