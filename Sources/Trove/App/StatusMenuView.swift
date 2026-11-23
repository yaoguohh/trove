import AppKit
import SwiftUI

/// The status menu's content: an app-icon header, permission warnings, sectioned rows with inline
/// switches bound straight to `AppSettings`, and a footer. `StatusMenuController` presents it in a
/// borderless drop-down under the menu-bar icon and supplies the snapshot values and actions.
struct StatusMenuView: View {
    @ObservedObject var settings: AppSettings
    let clipCount: Int
    let version: String
    let accessibilityTrusted: Bool
    let clipboardAccessNeedsAction: Bool
    let shortcutRegistered: Bool
    let canCheckForUpdates: Bool

    var onShow: () -> Void
    var onClearHistory: () -> Void
    var onCheckUpdates: () -> Void
    /// Dismiss the status menu (Esc).
    var onClose: () -> Void
    var onGrantAccessibility: () -> Void
    var onAllowClipboardAccess: () -> Void
    var onQuit: () -> Void

    /// One grid for every row (docs/DESIGN.md "对齐"): content keeps `inset` from both menu edges, row
    /// backgrounds (hover, tinted buttons) keep `rowInset`; icons center on one column and text starts
    /// on one line after it, from the header down to the last row.
    enum Layout {
        static let width: CGFloat = 300
        /// Menu edge to content, on both sides; the header and footer use it too.
        static let inset: CGFloat = 16
        /// Menu edge to a row's background, and the body's top and bottom padding.
        static let rowInset: CGFloat = 8
        /// A row's background to its content.
        static let rowPadding: CGFloat = inset - rowInset
        /// Icons center in this column; text starts `iconGap` after it.
        static let iconColumn: CGFloat = 20
        static let iconGap: CGFloat = 8
        static let rowHeight: CGFloat = 28
        static let buttonHeight: CGFloat = 32
        /// Between the tinted buttons and the rows, and around a separator.
        static let groupGap: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    if !accessibilityTrusted {
                        warningRow(
                            icon: "lock.shield.fill",
                            title: String(localized: "Turn On Auto-Paste..."),
                            detail: String(localized: "Needs \(PermissionGuide.accessibilityName) permission"),
                            action: onGrantAccessibility
                        )
                    }
                    if clipboardAccessNeedsAction {
                        warningRow(
                            icon: "doc.on.clipboard.fill",
                            title: String(localized: "Allow Clipboard Access..."),
                            detail: String(localized: "Allow Trove in Paste from Other Apps"),
                            action: onAllowClipboardAccess
                        )
                    }
                    showButton
                }
                .padding(.bottom, Layout.groupGap)

                toggleRow(icon: "link", title: String(localized: "Link Previews"), isOn: $settings.linkPreviews)
                toggleRow(icon: "menubar.rectangle", title: String(localized: "Run in Background"), isOn: $settings.runInBackground)

                separator

                shortcutRow

                separator

                actionRow(icon: "trash", title: String(localized: "Clear History..."), action: onClearHistory)
                actionRow(icon: "arrow.down.circle", title: String(localized: "Check for Updates..."), action: onCheckUpdates)
                    .disabled(!canCheckForUpdates)
                    .opacity(canCheckForUpdates ? 1 : 0.45)
            }
            .padding(Layout.rowInset)

            footer
        }
        .frame(width: Layout.width)
        // Tern's `popIn` for the content; the window only fades (`NSWindow.fadeIn`).
        .popIn()
        // The clipboard panel's material under the menu-strength tint, as Tern's menus.
        .background(GlassTint(opacity: Theme.Glass.menuOpacity))
        .background(GlassBackground())
        // Round the whole thing (glass + content): the borderless panel has no chrome of its own, and
        // its window shadow follows this rounded opaque shape.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Line.l2, lineWidth: 1)
        }
        // Esc dismisses the menu. A borderless panel doesn't close on Esc for free; this routes the cancel
        // command. While the shortcut recorder is recording, its local key monitor eats Esc first
        // (monitors run ahead of the responder chain), so Esc cancels recording rather than closing.
        .onExitCommand { onClose() }
    }

    /// Full width: it sets the header and footer apart from the body.
    private var hairline: some View {
        Rectangle().fill(Theme.Line.l2).frame(height: 1)
    }

    /// Between groups of rows: as wide as the content.
    private var separator: some View {
        hairline
            .padding(.horizontal, Layout.rowPadding)
            .padding(.vertical, Layout.groupGap / 2)
    }

    // MARK: Inline settings (Shortcut)

    private var shortcutRow: some View {
        HStack(spacing: Layout.iconGap) {
            rowIcon("command")
            VStack(alignment: .leading, spacing: 1) {
                Text("Shortcut").font(.system(size: 12)).foregroundStyle(Theme.Text.t1)
                if !shortcutRegistered {
                    // Another app already owns this combination; the panel can't be summoned with it.
                    Text("In use by another app").font(.system(size: 10)).foregroundStyle(Theme.Semantic.warn)
                }
            }
            Spacer(minLength: Layout.iconGap)
            ShortcutRecorder(settings: settings)
        }
        .padding(.horizontal, Layout.rowPadding)
        .frame(minHeight: Layout.rowHeight)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Layout.iconGap) {
            // Wider than the icon column; centered on it like every row icon below.
            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Surface.coal)
                )
                .frame(width: Layout.iconColumn)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Trove").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Theme.Text.t1)
                Text(clipCount == 1
                     ? String(localized: "1 clip kept")
                     : String(format: String(localized: "%lld clips kept"), clipCount))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Text.t2)
            }
            Spacer()
            Text(verbatim: "v\(version)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.Text.t3)
        }
        .padding(.horizontal, Layout.inset)
        .padding(.vertical, 12)
    }

    // MARK: Primary action

    private var showButton: some View {
        Button(action: onShow) {
            HStack(spacing: Layout.iconGap) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: Layout.iconColumn)
                Text("Show Trove").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Layout.rowPadding)
            .frame(height: Layout.buttonHeight)
            .frame(maxWidth: .infinity)
            .background(Theme.Accent.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Accent.hairline, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    /// A missing permission: what it unlocks, and on a second line what to do in System Settings.
    private func warningRow(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Layout.iconGap) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: Layout.iconColumn)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(Theme.Text.t2)
                }
                .lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
            }
            .foregroundStyle(Theme.Semantic.warn)
            .padding(.horizontal, Layout.rowPadding)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Theme.Semantic.warn.opacity(Theme.Tint.fill), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Semantic.warn.opacity(Theme.Tint.hairline), lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    // MARK: Rows

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        HoverRow {
            HStack(spacing: Layout.iconGap) {
                rowLabel(icon: icon, title: title)
                Spacer()
            }
        } action: { action() }
    }

    private func toggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HoverRow {
            HStack(spacing: Layout.iconGap) {
                rowLabel(icon: icon, title: title)
                Spacer()
                MiniSwitch(isOn: isOn.wrappedValue)
            }
        } action: {
            isOn.wrappedValue.toggle()
        }
    }

    private func rowIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 12)).frame(width: Layout.iconColumn).foregroundStyle(Theme.Text.t3)
    }

    @ViewBuilder
    private func rowLabel(icon: String, title: String) -> some View {
        rowIcon(icon)
        Text(title).font(.system(size: 12)).foregroundStyle(Theme.Text.t1)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Local · MIT").font(.system(size: 10)).foregroundStyle(Theme.Text.t3)
            Spacer()
            Button(action: onQuit) {
                HStack(spacing: 4) {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text("Quit").font(.system(size: 11))
                }
                .foregroundStyle(Theme.Text.t2)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, Layout.inset)
        .padding(.vertical, 8)
        .overlay(hairline, alignment: .top)
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
                .padding(.horizontal, StatusMenuView.Layout.rowPadding)
                .frame(height: StatusMenuView.Layout.rowHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                        .fill(hovering ? Theme.Line.l1 : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.ease, value: hovering)
    }
}

/// A small non-interactive switch indicator (the row owns the tap), drawn to read as a settings toggle.
private struct MiniSwitch: View {
    let isOn: Bool
    var body: some View {
        Capsule()
            .fill(isOn ? Theme.accent : Theme.Line.l4)
            .frame(width: 26, height: 15)
            .overlay(
                Circle().fill(isOn ? Theme.Surface.coal : Theme.Text.t1).padding(2),
                alignment: isOn ? .trailing : .leading
            )
            .animation(Theme.Motion.out(), value: isOn)
    }
}

/// The panel's glass (`PanelChrome.makeGlass`) as a SwiftUI background.
private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        PanelChrome.makeGlass()
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
