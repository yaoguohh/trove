import SwiftUI

/// The toolbar's row of pinboard chips plus the "+" button, with home-screen-style drag-to-reorder.
/// Owns all of the reorder gesture state so `ClipboardPanelView` stays about the timeline.
struct PinboardStrip: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var model: PanelViewModel
    /// Gap between chips (the toolbar's spacing, so the strip reads as part of the toolbar row).
    let spacing: CGFloat
    /// Shared toolbar item height so every control shares one vertical center.
    let itemHeight: CGFloat

    @State private var draggingPinboardID: UUID?
    @State private var dragCursorX: CGFloat = 0
    @State private var dragGrabOffset: CGFloat = 0
    @State private var dragTargetIndex: Int?
    @State private var chipFrames: [UUID: CGRect] = [:]

    private static let rowSpace = "pinboardRow"

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(store.pinboards.enumerated()), id: \.element.id) { index, pinboard in
                chip(pinboard, originalIndex: index)
            }

            Button {
                store.createPinboard(
                    named: String(localized: "Pinboard \(store.pinboards.count + 1)"),
                    colorName: PinboardColor.nextColorName(forExistingCount: store.pinboards.count)
                )
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 30, height: itemHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.Text.t1)
        }
        .coordinateSpace(name: Self.rowSpace)
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

    @ViewBuilder
    private func chip(_ pinboard: Pinboard, originalIndex: Int) -> some View {
        let isDragging = draggingPinboardID == pinboard.id
        TopPinboardButton(
            pinboard: pinboard,
            color: PinboardColor.color(named: pinboard.colorName),
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
        .frame(height: itemHeight)
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
                    value: [pinboard.id: geo.frame(in: .named(Self.rowSpace))]
                )
            }
        )
        .offset(x: chipOffsetX(pinboard.id, originalIndex: originalIndex))
        .scaleEffect(isDragging ? 1.05 : 1)
        .shadow(color: .black.opacity(isDragging ? 0.22 : 0), radius: isDragging ? 8 : 0, y: 3)
        .zIndex(isDragging ? 1 : 0)
        // High priority so a real drag (≥8pt) pre-empts the button's tap; a clean click
        // never starts the drag and still toggles the filter.
        .highPriorityGesture(dragGesture(pinboard))
    }

    private func dragGesture(_ pinboard: Pinboard) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.rowSpace))
            .onChanged { value in
                if draggingPinboardID != pinboard.id {
                    let midX = chipFrames[pinboard.id]?.midX ?? value.startLocation.x
                    dragGrabOffset = value.startLocation.x - midX
                    withAnimation(Theme.Motion.spring(response: 0.25, dampingFraction: 0.72)) {
                        draggingPinboardID = pinboard.id
                    }
                }
                dragCursorX = value.location.x
                let newTarget = targetIndex(draggedID: pinboard.id, cursorX: value.location.x)
                if newTarget != dragTargetIndex {
                    withAnimation(Theme.Motion.spring(response: 0.3, dampingFraction: 0.78)) {
                        dragTargetIndex = newTarget
                    }
                }
            }
            .onEnded { _ in
                finishDrag()
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
        let footprint = (chipFrames[draggingID]?.width ?? 0) + spacing
        if from < target, originalIndex > from, originalIndex <= target { return -footprint }
        if target < from, originalIndex >= target, originalIndex < from { return footprint }
        return 0
    }

    private func targetIndex(draggedID: UUID, cursorX: CGFloat) -> Int {
        let center = cursorX - dragGrabOffset
        var leftOfCenter = 0
        for other in store.pinboards where other.id != draggedID {
            if let midX = chipFrames[other.id]?.midX, midX < center { leftOfCenter += 1 }
        }
        return leftOfCenter
    }

    private func finishDrag() {
        guard let id = draggingPinboardID else { return }
        let target = dragTargetIndex
        withAnimation(Theme.Motion.spring(response: 0.3, dampingFraction: 0.8)) {
            if let target { store.movePinboard(id, toIndex: target) }
            draggingPinboardID = nil
            dragTargetIndex = nil
            dragCursorX = 0
            dragGrabOffset = 0
        }
    }
}

/// Collects each pinboard chip's laid-out frame (in the strip's coordinate space) so the
/// gesture reorder can tell which slot the dragged chip is over. `.offset` is a render-time
/// transform, so the reported frames stay at the stable base slots during a drag.
private struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
