import AppKit
import SwiftUI

/// The welcome window's content: Trove's icon and a headline, three lines on how Trove is used (fresh
/// install only), then the two permissions with their live state and the action that fixes each.
struct WelcomeView: View {
    let reason: WelcomeController.Reason
    /// The summon shortcut as key-cap symbols, e.g. "⇧⌘V".
    let shortcut: String
    @ObservedObject var status: PermissionStatus
    var onGrantAccessibility: () -> Void
    var onOpenClipboardSettings: () -> Void
    var onDone: () -> Void

    /// The window's grid (docs/DESIGN.md "对齐"). Feature tiles and the permission card share the left
    /// edge, and feature text and permission text start on one line: the permission icon column is the
    /// tile's width less the card's padding.
    enum Layout {
        static let width: CGFloat = 440
        /// Window edge to content on the sides and at the bottom.
        static let inset: CGFloat = 28
        /// Title bar to the icon: the view starts under the transparent title bar.
        static let top: CGFloat = 40
        static let sectionGap: CGFloat = 24
        static let appIcon: CGFloat = 52
        static let tile: CGFloat = 30
        static let iconGap: CGFloat = 12
        static let cardPadding: CGFloat = 12
        static let permissionIcon: CGFloat = tile - cardPadding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionGap) {
            header
            if reason == .firstLaunch {
                features
            }
            permissions
            HStack {
                Spacer()
                Button(action: onDone) {
                    Text(status.accessibilityGranted ? String(localized: "Done") : String(localized: "Later"))
                        .modifier(ButtonFace(prominent: status.accessibilityGranted))
                }
                .buttonStyle(.pressable)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, Layout.inset)
        .padding(.top, Layout.top)
        .padding(.bottom, Layout.inset)
        .frame(width: Layout.width)
        .background(Theme.Surface.coal)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 6) {
            AppIconImage(image: NSApp.applicationIconImage, size: Layout.appIcon)
                .padding(.bottom, 10)
            Text(reason == .firstLaunch ? String(localized: "Welcome to Trove") : String(localized: "Turn On Auto-Paste"))
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.Text.t1)
            Text(reason == .firstLaunch
                 ? String(localized: "Everything you copy, one shortcut away.")
                 : String(localized: "This clip is on the clipboard, so ⌘V pastes it. Once Trove has access, choosing a card pastes it for you."))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Text.t2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: How Trove is used

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            feature(icon: "keyboard",
                    title: String(localized: "Press \(shortcut) in any app"),
                    detail: String(localized: "Your clipboard history opens over the app you're in."))
            feature(icon: "return",
                    title: String(localized: "Choose a card to paste it"),
                    detail: String(localized: "Return or a click puts it into the field you were typing in."))
            feature(icon: "pin.fill",
                    title: String(localized: "Pin what you reuse"),
                    detail: String(localized: "Pinned clips are never cleared, and pinboards group them."))
        }
    }

    private func feature(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Layout.iconGap) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: Layout.tile, height: Layout.tile)
                .background(Theme.Accent.fill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Text.t1)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.Text.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Permissions

    private var permissions: some View {
        VStack(spacing: 0) {
            permissionRow(
                icon: "lock.shield.fill",
                title: PermissionGuide.accessibilityName,
                detail: String(localized: "Lets Trove paste into the app you were in."),
                granted: status.accessibilityGranted,
                action: Text("Allow..."),
                prominent: true,
                perform: onGrantAccessibility
            )
            if ClipboardAccessPermission.isAvailable {
                // Starts where the text does.
                Rectangle().fill(Theme.Line.l2).frame(height: 1)
                    .padding(.leading, Layout.cardPadding + Layout.permissionIcon + Layout.iconGap)
                permissionRow(
                    icon: "doc.on.clipboard.fill",
                    title: String(localized: "Paste from Other Apps"),
                    detail: String(localized: "Allow Trove here, or macOS asks before each copy is recorded."),
                    granted: status.clipboardAllowed,
                    action: Text("Open Settings..."),
                    prominent: false,
                    perform: onOpenClipboardSettings
                )
            }
        }
        .background(Theme.Surface.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.Line.l2, lineWidth: 1)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        granted: Bool,
        action: Text,
        prominent: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Layout.iconGap) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(granted ? Theme.Text.t3 : Theme.Semantic.warn)
                .frame(width: Layout.permissionIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Text.t1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.Text.t2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Layout.iconGap)
            if granted {
                Label { Text("Allowed") } icon: { Image(systemName: "checkmark") }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Text.t2)
            } else {
                Button(action: perform) {
                    action.modifier(ButtonFace(prominent: prominent))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(Layout.cardPadding)
        .animation(Theme.Motion.ease, value: granted)
    }
}

/// The two button looks in the window: `prominent` is the ember primary action, the other a quiet
/// line-ladder control.
private struct ButtonFace: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        content
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Theme.accent : Theme.Text.t1)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(prominent ? Theme.Accent.fill : Theme.Line.l1,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(prominent ? Theme.Accent.hairline : Theme.Line.l2, lineWidth: 1)
            }
            .contentShape(Rectangle())
    }
}
