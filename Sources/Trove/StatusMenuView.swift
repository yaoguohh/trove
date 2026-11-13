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

    private let width: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            header
            hairline

            VStack(spacing: 2) {
                if !accessibilityTrusted {
                    warningRow(icon: "lock.shield.fill", title: String(localized: "Grant Accessibility Permission..."), action: onGrantAccessibility)
                    Rectangle().fill(.clear).frame(height: 4)
                }
                if clipboardAccessNeedsAction {
                    warningRow(icon: "doc.on.clipboard.fill", title: String(localized: "Allow Clipboard Access..."), action: onAllowClipboardAccess)
                    Rectangle().fill(.clear).frame(height: 4)
                }

                showButton

                Rectangle().fill(.clear).frame(height: 6)

                toggleRow(icon: "link", title: String(localized: "Link Previews"), isOn: $settings.linkPreviews)
                toggleRow(icon: "menubar.rectangle", title: String(localized: "Run in Background"), isOn: $settings.runInBackground)

                hairline.padding(.vertical, 5).padding(.horizontal, 4)

                shortcutRow

                hairline.padding(.vertical, 5).padding(.horizontal, 4)

                actionRow(icon: "trash", title: String(localized: "Clear History..."), action: onClearHistory)
                actionRow(icon: "arrow.down.circle", title: String(localized: "Check for Updates..."), action: onCheckUpdates)
                    .disabled(!canCheckForUpdates)
                    .opacity(canCheckForUpdates ? 1 : 0.45)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)

            footer
        }
        .frame(width: width)
        // Tern's `popIn` for the content; the window itself fades in (AppDelegate) so the behind-window
        // blur is never transformed per frame.
        .popIn()
        // The same dense .hudWindow glass as the clipboard panel, so the menu reads as a solid surface.
        .background(VisualEffectBackground(material: .hudWindow))
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

    private var hairline: some View {
        Rectangle().fill(Theme.Line.l2).frame(height: 1)
    }

    // MARK: Inline settings (Shortcut)

    private var shortcutRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "command").font(.system(size: 12)).frame(width: 17).foregroundStyle(Theme.Text.t3)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "Shortcut")).font(.system(size: 12)).foregroundStyle(Theme.Text.t1)
                if !shortcutRegistered {
                    // Another app already owns this combination; the panel can't be summoned with it.
                    Text(String(localized: "In use by another app")).font(.system(size: 10)).foregroundStyle(Theme.Semantic.warn)
                }
            }
            Spacer(minLength: 8)
            ShortcutRecorder(settings: settings)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 30)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 24, height: 24)
                .overlay(
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Surface.coal)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Trove").font(.system(size: 13.5, weight: .bold)).foregroundStyle(Theme.Text.t1)
                Text(clipCount == 1
                     ? String(localized: "1 clip kept")
                     : String(format: String(localized: "%lld clips kept"), clipCount))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Text.t2)
            }
            Spacer()
            Text("v\(version)")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Theme.Text.t3)
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
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Theme.Accent.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Accent.hairline, lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    private func warningRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Spacer()
            }
            .foregroundStyle(Theme.Semantic.warn)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity)
            .background(Theme.Semantic.warn.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.Semantic.warn.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.pressable)
    }

    // MARK: Rows

    private func actionRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 17).foregroundStyle(Theme.Text.t3)
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.Text.t1)
                Spacer()
            }
        } action: { action() }
    }

    private func toggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HoverRow {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12)).frame(width: 17).foregroundStyle(Theme.Text.t3)
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.Text.t1)
                Spacer()
                MiniSwitch(isOn: isOn.wrappedValue)
            }
        } action: {
            isOn.wrappedValue.toggle()
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text(String(localized: "Local · MIT")).font(.system(size: 10)).foregroundStyle(Theme.Text.t3)
            Spacer()
            Button(action: onQuit) {
                HStack(spacing: 5) {
                    Image(systemName: "power").font(.system(size: 11, weight: .medium))
                    Text(String(localized: "Quit")).font(.system(size: 11))
                }
                .foregroundStyle(Theme.Text.t2)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
                .padding(.horizontal, 8)
                .frame(height: 28)
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
            .animation(Theme.Motion.out(0.2), value: isOn)
    }
}

/// A dense frosted background blended behind the window (like the Dock / a native menu), so the
/// menu stays opaque over busy backgrounds. `isEmphasized` + full opacity make the blur — not
/// alpha — do the hiding.
private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
