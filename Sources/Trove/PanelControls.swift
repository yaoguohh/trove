import SwiftUI

struct HistorySearchField: View {
    @Binding var query: String
    /// Drives the active vs dim look.
    var isActive: Bool
    /// The shared single focus authority (see PanelFocus). This field is `.search`.
    var focus: FocusState<PanelFocus?>.Binding
    let activate: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Baseline-align the magnifier with the field text so they sit level (centering
            // alone left the icon optically high against the text baseline).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Text.t3)

                // Placeholder always shows when empty; the field is always the text first
                // responder so typing never loses its first character.
                TextField("", text: $query, prompt: Text("Clipboard history"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Text.t1)
                    .frame(width: 150) // fixed width: animating it shifted the pinboards and made clicks miss
                    .focused(focus, equals: .search)
                    // Navigation/action keys are intercepted at the window level (the controller's
                    // keyDown monitor → PanelKeyboard), so they work even if this field loses focus;
                    // this field just edits the search text for the printable keys that fall through.
                    .onChange(of: query) {
                        activate()
                    }
            }

            if !query.isEmpty {
                Button {
                    query = ""
                    activate()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(Theme.Text.t3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // Flat fill + hairline from the line ladder (no Material, so the glass vibrancy can't tint
        // it). Active = one step up the ladder; no accent ring — Tern drops the ring on text inputs,
        // and this field is focused nearly all the time.
        .background(isActive ? Theme.Line.l2 : Theme.Line.l1, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(isActive ? Theme.Line.l3 : Theme.Line.l2, lineWidth: 1)
        }
        .animation(Theme.Motion.ease, value: isActive)
        .contentShape(Capsule())
        .onTapGesture {
            focus.wrappedValue = .search
            activate()
        }
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
