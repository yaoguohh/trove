import SwiftUI

struct HistorySearchField: View {
    @Binding var query: String
    /// Drives the active vs dim look.
    var isActive: Bool
    /// The shared single focus authority (see PanelFocus). This field is `.search`.
    var focus: FocusState<PanelFocus?>.Binding
    /// Routes a key press to the controller; returns true when it was intercepted (`.handled`).
    let handleKey: (KeyEquivalent, EventModifiers) -> Bool
    let activate: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            // Baseline-align the magnifier with the field text so they sit level (centering
            // alone left the icon optically high against the text baseline).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                // Placeholder always shows when empty; the field is always the text first
                // responder so typing never loses its first character.
                TextField("", text: $query, prompt: Text("Clipboard history"))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 150) // fixed width: animating it shifted the pinboards and made clicks miss
                    .focused(focus, equals: .search)
                    // Navigation/action keys are intercepted here and routed to the card selection
                    // (.handled); printable keys and ⌫ return .ignored and edit the search natively.
                    .onKeyPress { press in
                        handleKey(press.key, press.modifiers) ? .handled : .ignored
                    }
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
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(searchBackground, in: Capsule())
        .overlay {
            Capsule()
                .stroke(strokeColor, lineWidth: 1)
        }
        .contentShape(Capsule())
        .onTapGesture {
            focus.wrappedValue = .search
            activate()
        }
    }

    // Flat, monochrome fill/border (no Material, so the glass vibrancy can't tint it
    // pink/purple); adaptive to light/dark, stronger while editing.
    private var searchBackground: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(Color.white.opacity(isActive ? 0.16 : 0.08))
        }
        return AnyShapeStyle(Color.black.opacity(isActive ? 0.08 : 0.04))
    }

    private var strokeColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isActive ? 0.26 : 0.12)
        }
        return Color.black.opacity(isActive ? 0.22 : 0.10)
    }
}

struct TopPinboardButton: View {
    let pinboard: Pinboard
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 11, height: 11)
                Text(pinboard.name)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? color.opacity(0.16) : Color.clear, in: Capsule())
            // Without this the padding around the label isn't tappable (.plain buttons
            // only hit the text/icon), which made the pill feel unclickable at its edges.
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
