import SwiftUI

/// The menu-bar status menu, rendered as a designed SwiftUI panel (shown in an NSPopover) instead of a
/// stock `NSMenu`: an app-icon header, sectioned rows with SF Symbol glyphs, inline switches for the
/// toggles, and a footer — the polished look of a modern menu-bar app. Pure view; AppDelegate injects
/// the current state and the action callbacks.
struct StatusMenuView: View {
    let clipCount: Int
    let version: String
    let accessibilityTrusted: Bool
    @State var linkPreviewsOn: Bool
    @State var runInBackground: Bool

    var onShow: () -> Void
    var onToggleLinkPreviews: () -> Void
    var onToggleBackground: () -> Void
    var onClearHistory: () -> Void
    var onCheckUpdates: () -> Void
    var onPreferences: () -> Void
    var onGrantAccessibility: () -> Void
    var onQuit: () -> Void

    private let accent = Color.accentColor
    private let width: CGFloat = 282

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            VStack(spacing: 2) {
                if !accessibilityTrusted {
                    accessibilityRow
                    Rectangle().fill(.clear).frame(height: 4)
                }

                showButton

                Rectangle().fill(.clear).frame(height: 6)

                toggleRow(icon: "link", title: String(localized: "Link Previews"), isOn: $linkPreviewsOn) {
                    onToggleLinkPreviews()
                }
                toggleRow(icon: "menubar.rectangle", title: String(localized: "Run in Background"), isOn: $runInBackground) {
                    onToggleBackground()
                }

                Divider().opacity(0.25).padding(.vertical, 5).padding(.horizontal, 4)

                actionRow(icon: "trash", title: String(localized: "Clear History"), action: onClearHistory)
                actionRow(icon: "arrow.down.circle", title: String(localized: "Check for Updates..."), action: onCheckUpdates)
                actionRow(icon: "gearshape", title: String(localized: "Preferences..."), shortcut: "⌘,", action: onPreferences)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            footer
        }
        .frame(width: width)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Trove").font(.system(size: 13.5, weight: .bold))
                Text(clipCount == 1
                     ? String(localized: "1 clip kept")
                     : String(format: String(localized: "%lld clips kept"), clipCount))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(version)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    // MARK: Primary action

    private var showButton: some View {
        Button(action: onShow) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 11.5, weight: .semibold))
                Text(String(localized: "Show Trove")).font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(accent)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(accent.opacity(0.22), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private var accessibilityRow: some View {
        Button(action: onGrantAccessibility) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield.fill").font(.system(size: 12, weight: .semibold))
                Text(String(localized: "Grant Accessibility Permission...")).font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
            }
            .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.20))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Color(red: 1.0, green: 0.62, blue: 0.20).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows

    private func actionRow(icon: String, title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 17).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12))
                Spacer()
                if let shortcut {
                    Text(shortcut).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        } action: { action() }
    }

    private func toggleRow(icon: String, title: String, isOn: Binding<Bool>, onToggle: @escaping () -> Void) -> some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 17).foregroundStyle(.secondary)
                Text(title).font(.system(size: 12))
                Spacer()
                MiniSwitch(isOn: isOn.wrappedValue)
            }
        } action: {
            isOn.wrappedValue.toggle()
            onToggle()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Local · MIT")).font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Button(action: onQuit) {
                HStack(spacing: 5) {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text(String(localized: "Quit")).font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(Divider().opacity(0.4), alignment: .top)
    }
}

/// A menu row with a hover highlight, matching the feel of a native menu item.
private struct HoverRow<Content: View>: View {
    @ViewBuilder var content: Content
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A small non-interactive switch indicator (the row owns the tap), drawn to read as a settings toggle.
private struct MiniSwitch: View {
    let isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(width: 26, height: 15)
            .overlay(
                Circle().fill(.white).padding(2),
                alignment: isOn ? .trailing : .leading
            )
            .animation(.easeOut(duration: 0.15), value: isOn)
    }
}
