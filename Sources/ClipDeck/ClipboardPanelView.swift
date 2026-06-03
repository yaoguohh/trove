import AppKit
import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var store: ClipboardStore
    let monitor: ClipboardMonitor
    @ObservedObject var model: PanelViewModel
    let close: () -> Void
    let reopen: () -> Void
    let openSettings: () -> Void
    let preview: (ClipboardItem) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredID: ClipboardItem.ID?
    @State private var suppressHoverScroll = false
    @State private var draggingPinboardID: UUID?
    @State private var dragCursorX: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    @State private var dragTargetIndex: Int?
    @State private var chipFrames: [UUID: CGRect] = [:]
    // The search field is always the text first responder (so the first keystroke is never
    // lost). ↑/↓ move the card selection via the controller's key monitor; ←/→ edit text.
    @FocusState private var searchFocused: Bool

    private static let toolbarSpacing: CGFloat = 14
    // Shared height for every toolbar item so they share one vertical center / equal top margin.
    private static let toolbarItemHeight: CGFloat = 36
    private static let pinboardRowSpace = "pinboardRow"

    private var filteredItems: [ClipboardItem] { model.filteredItems }

    var body: some View {
        VStack(spacing: 0) {
            pasteToolbar
                .zIndex(0)
            timeline
                .zIndex(2)
        }
        .frame(minWidth: 720, minHeight: 240)
        .background {
            // 16pt corners must match the glass mask in ClipboardPanelController.cornerRadius.
            // No fill tint and no top sheen — the user asked to strip the residual white so the
            // chrome is as see-through as possible; just the material plus a hairline edge.
            RoundedRectangle(cornerRadius: ClipboardPanelController.cornerRadius, style: .continuous)
                .fill(panelOverlay)
                .overlay {
                    RoundedRectangle(cornerRadius: ClipboardPanelController.cornerRadius, style: .continuous)
                        .stroke(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.10), lineWidth: 1)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: ClipboardPanelController.cornerRadius, style: .continuous))
        .onTapGesture {
            // Clicking empty panel chrome leaves editing for the card row.
            model.isEditing = false
        }
        .onAppear {
            model.selectFirst()
        }
        .onChange(of: model.showToken) {
            // Every (re)show starts on the card row (not editing), per the two-row model.
            searchFocused = false
        }
        .onChange(of: model.isEditing) {
            // Editing state owns the search-field focus (so the caret shows only when editing).
            searchFocused = model.isEditing
        }
        .onChange(of: searchFocused) {
            // Keep them in lockstep both ways so focus and editing don't desync.
            model.isEditing = searchFocused
        }
        .onChange(of: model.query) {
            model.selectFirst()
        }
        .onChange(of: model.filter) {
            model.selectFirst()
        }
    }

    private var panelOverlay: Color {
        // No white veil at all (the user's call): the chrome's translucency is the material
        // alone — the most see-through standard material. If a dark wallpaper makes light mode
        // look a touch muddy, that's the trade for maximum Dock-like transparency.
        Color.clear
    }

    private var pasteToolbar: some View {
        HStack(alignment: .center, spacing: Self.toolbarSpacing) {
            Button {
                model.filter = ClipboardSearchFilter()
                model.query = ""
                model.isEditing = false
                model.selectFirst()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 30, height: Self.toolbarItemHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HistorySearchField(
                query: $model.query,
                isActive: model.isEditing,
                searchFocused: $searchFocused,
                activate: {
                    model.filter.scope = .history
                    model.filter.pinboardID = nil
                }
            )
            // Uniform 36pt height across all toolbar items so they share one vertical center and
            // an equal top margin (the search field was taller than the icon buttons before).
            .frame(height: Self.toolbarItemHeight)

            ForEach(Array(store.pinboards.enumerated()), id: \.element.id) { index, pinboard in
                pinboardChip(pinboard, originalIndex: index)
            }

            Button {
                store.createPinboard(named: String(localized: "Pinboard \(store.pinboards.count + 1)"), colorName: nextColorName())
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 30, height: Self.toolbarItemHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Spacer(minLength: 0)

            moreActionsMenu
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .coordinateSpace(name: Self.pinboardRowSpace)
        .onPreferenceChange(ChipFramePreferenceKey.self) { frames in
            // onPreferenceChange's action is @Sendable under Swift 6 but SwiftUI delivers it on
            // the main thread, so hop to the main actor to touch the view's @State.
            MainActor.assumeIsolated {
                // Freeze measurements during a drag. `frame(in:)` includes a view's own
                // `.offset`, so reading it back to compute that same offset is a positive
                // feedback loop (the chip's offset diverges — laggy, flies off screen). The
                // row layout is stable mid-drag (the array only changes on release), so the
                // slots captured just before the drag stay valid; with frozen slots the
                // dragged chip's offset reduces to a plain cursor-minus-start translation.
                guard draggingPinboardID == nil else { return }
                chipFrames = frames
            }
        }
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
            Button {
                close()
                openSettings()
            } label: {
                Label("Preferences...", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
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
                                        metrics: metrics
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
                                    }
                                    .zIndex(hoveredID == item.id ? 20 : model.selectedID == item.id ? 10 : 0)
                                    .onHover { isHovering in
                                        withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                                            hoveredID = isHovering ? item.id : nil
                                        }
                                        // Hovering moves the selection ring to follow the mouse,
                                        // but must not auto-scroll (the card is already visible).
                                        if isHovering, model.selectedID != item.id {
                                            suppressHoverScroll = true
                                            model.selectedID = item.id
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
                                withAnimation(.snappy) {
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
                .foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.headline)
            Text("Copy something and it will appear in this tray.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            metrics: metrics
        )
        .frame(width: metrics.width, height: metrics.height)
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: card)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    // MARK: - Pinboard reordering (gesture-driven, home-screen style)

    @ViewBuilder
    private func pinboardChip(_ pinboard: Pinboard, originalIndex: Int) -> some View {
        let isDragging = draggingPinboardID == pinboard.id
        TopPinboardButton(
            pinboard: pinboard,
            color: color(for: pinboard),
            isSelected: model.filter.pinboardID == pinboard.id
        ) {
            // Toggle: clicking the selected pinboard again clears the filter (all history).
            if model.filter.pinboardID == pinboard.id {
                model.filter.scope = .history
                model.filter.pinboardID = nil
            } else {
                model.filter.scope = .pinned
                model.filter.pinboardID = pinboard.id
            }
        }
        .frame(height: 36)
        .contextMenu {
            Button("Delete Pinboard", role: .destructive) {
                store.deletePinboard(pinboard)
                if model.filter.pinboardID == pinboard.id {
                    model.filter.pinboardID = nil
                    model.filter.scope = .history
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ChipFramePreferenceKey.self,
                    value: [pinboard.id: geo.frame(in: .named(Self.pinboardRowSpace))]
                )
            }
        )
        .offset(x: chipOffsetX(pinboard.id, originalIndex: originalIndex))
        .scaleEffect(isDragging ? 1.05 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: isDragging ? 8 : 0, y: 3)
        .zIndex(isDragging ? 1 : 0)
        // High priority so a real drag (≥8pt) pre-empts the button's tap; a clean click
        // never starts the drag and still toggles the filter.
        .highPriorityGesture(pinboardDragGesture(pinboard))
    }

    private func pinboardDragGesture(_ pinboard: Pinboard) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.pinboardRowSpace))
            .onChanged { value in
                if draggingPinboardID != pinboard.id {
                    let midX = chipFrames[pinboard.id]?.midX ?? value.startLocation.x
                    dragGrabOffset = value.startLocation.x - midX
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.72)) {
                        draggingPinboardID = pinboard.id
                    }
                }
                dragCursorX = value.location.x
                let newTarget = computePinboardTargetIndex(draggedID: pinboard.id, cursorX: value.location.x)
                if newTarget != dragTargetIndex {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                        dragTargetIndex = newTarget
                    }
                }
            }
            .onEnded { _ in
                finishPinboardDrag()
            }
    }

    /// The dragged chip is glued to the cursor; the others slide one footprint aside to open
    /// a gap at the target slot (the iOS home-screen "make room" behavior).
    private func chipOffsetX(_ id: UUID, originalIndex: Int) -> CGFloat {
        guard let draggingID = draggingPinboardID else { return 0 }
        if draggingID == id {
            let midX = chipFrames[id]?.midX ?? dragCursorX
            return dragCursorX - dragGrabOffset - midX
        }
        guard let from = store.pinboards.firstIndex(where: { $0.id == draggingID }),
              let target = dragTargetIndex else { return 0 }
        let footprint = (chipFrames[draggingID]?.width ?? 0) + Self.toolbarSpacing
        if from < target, originalIndex > from, originalIndex <= target { return -footprint }
        if target < from, originalIndex >= target, originalIndex < from { return footprint }
        return 0
    }

    private func computePinboardTargetIndex(draggedID: UUID, cursorX: CGFloat) -> Int {
        let center = cursorX - dragGrabOffset
        var leftOfCenter = 0
        for other in store.pinboards where other.id != draggedID {
            if let midX = chipFrames[other.id]?.midX, midX < center { leftOfCenter += 1 }
        }
        return leftOfCenter
    }

    private func finishPinboardDrag() {
        guard let id = draggingPinboardID else { return }
        let target = dragTargetIndex
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if let target { store.movePinboard(id, toIndex: target) }
            draggingPinboardID = nil
            dragTargetIndex = nil
            dragCursorX = 0
            dragGrabOffset = 0
        }
    }

    private func pinboard(for item: ClipboardItem) -> Pinboard? {
        guard let id = item.pinboardID else { return nil }
        return store.pinboards.first { $0.id == id }
    }

    private func nextColorName() -> String {
        PinboardColor.nextColorName(forExistingCount: store.pinboards.count)
    }

    private func color(for pinboard: Pinboard) -> Color {
        PinboardColor.color(named: pinboard.colorName)
    }
}

/// Collects each pinboard chip's laid-out frame (in the toolbar's coordinate space) so the
/// gesture reorder can tell which slot the dragged chip is over. `.offset` is a render-time
/// transform, so the reported frames stay at the stable base slots during a drag.
private struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
