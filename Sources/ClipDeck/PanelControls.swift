import SwiftUI

struct HistorySearchField: View {
    @Binding var query: String
    /// true while editing (search field focused) — drives the active vs dim look. The card
    /// row is the default, so the field reads dim until the user types / ↑ / clicks it.
    var isActive: Bool
    var searchFocused: FocusState<Bool>.Binding
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
                    .focused(searchFocused)
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
            searchFocused.wrappedValue = true
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
