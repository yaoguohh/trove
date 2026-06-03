import AppKit
import SwiftUI

@MainActor
final class SettingsPanelController {
    private let shortcutStore: ShortcutStore
    private var window: NSWindow?

    init(shortcutStore: ShortcutStore) {
        self.shortcutStore = shortcutStore
    }

    func show() {
        if window == nil {
            createWindow()
        }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func createWindow() {
        let view = SettingsView(shortcutStore: shortcutStore)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "ClipDeck Preferences")
        window.isReleasedWhenClosed = false
        window.contentViewController = hosting
        self.window = window
    }
}

private struct SettingsView: View {
    @ObservedObject var shortcutStore: ShortcutStore
    @State private var appearance = AppearanceManager.current

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(AppAppearance.allCases) { option in
                        AppearanceOptionCard(option: option, isSelected: appearance == option) {
                            appearance = option
                            AppearanceManager.current = option
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Choose how ClipDeck looks. Follow System matches your macOS setting.")
            }

            Section {
                ShortcutRecorder(shortcutStore: shortcutStore)
                    .padding(.vertical, 2)
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Choose the global shortcut used to show or hide ClipDeck. Press a combination with at least one modifier key.")
            }
        }
        .formStyle(.grouped)
        // Explicit size: as a window contentViewController the hosting view defines the
        // window size, and a frame-less Form collapses to ~0 height (blank window).
        .frame(width: 500, height: 460)
    }
}

/// A macOS System Settings-style appearance card: a small window preview with a
/// selection ring and a labeled radio indicator below.
private struct AppearanceOptionCard: View {
    let option: AppAppearance
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            preview
                .frame(width: 96, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.35),
                                lineWidth: isSelected ? 3 : 1)
                }

            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(option.title)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var preview: some View {
        switch option {
        case .light:
            miniWindow(.light)
        case .dark:
            miniWindow(.dark)
        case .system:
            HStack(spacing: 0) {
                miniWindow(.light)
                miniWindow(.dark)
            }
        }
    }

    private enum Tone { case light, dark }

    private func miniWindow(_ tone: Tone) -> some View {
        let bg = tone == .light ? Color.white : Color(white: 0.16)
        let bar = tone == .light ? Color(white: 0.86) : Color(white: 0.30)
        let line = tone == .light ? Color(white: 0.72) : Color(white: 0.46)
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Circle().fill(line).frame(width: 4, height: 4)
                Circle().fill(line).frame(width: 4, height: 4)
                Circle().fill(line).frame(width: 4, height: 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5)
            .frame(height: 14)
            .frame(maxWidth: .infinity)
            .background(bar)

            VStack(alignment: .leading, spacing: 3) {
                RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 28, height: 3)
                RoundedRectangle(cornerRadius: 1).fill(line.opacity(0.7)).frame(width: 36, height: 3)
                RoundedRectangle(cornerRadius: 1).fill(line.opacity(0.7)).frame(width: 22, height: 3)
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(bg)
        }
    }
}
