import SwiftUI

/// The toolbar's row of pinboard chips plus the "+" button, with home-screen-style drag-to-reorder.
/// Owns all of the reorder gesture state so `PanelView` stays about the timeline.
struct PinboardStrip: View {
    @ObservedObject var store: ClipStore
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
            model.filter.pinboardID = model.filter.pinboardID == pinboard.id ? nil : pinboard.id
        }
        .frame(height: itemHeight)
        .contextMenu {
            Button("Delete Pinboard", role: .destructive) {
                store.deletePinboard(pinboard)
                if model.filter.pinboardID == pinboard.id {
                    model.filter.pinboardID = nil
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
        .shadow(isDragging ? Theme.Shadow.lifted : ShadowStyle(opacity: 0, radius: 0, y: 0))
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
/// gesture reorder can tell which slot the dragged chip is over. The frames include a chip's own
/// `.offset`, which is why the strip stops reading them while a drag is in progress.
private struct ChipFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TopPinboardButton: View {
    let pinboard: Pinboard
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                Text(pinboard.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.Text.t1 : Theme.Text.t2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // Selected: the pinboard's own color at 16% (Tern's selected-fill step); hover: l1.
            .background(isSelected ? color.opacity(0.16) : hovering ? Theme.Line.l1 : Color.clear, in: Capsule())
            // Without this the padding around the label isn't tappable (.plain buttons
            // only hit the text/icon), which made the pill feel unclickable at its edges.
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.ease, value: hovering)
        .animation(Theme.Motion.ease, value: isSelected)
    }
}
