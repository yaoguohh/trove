import AppKit
import SwiftUI

/// A rounded key-cap badge, e.g. ⇧ ⌘ V.
struct KeyCapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(minWidth: 24)
            .frame(height: 26)
            .padding(.horizontal, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.primary.opacity(0.10), lineWidth: 1)
            }
    }
}

/// Records a global shortcut, showing key-cap badges and the live-held modifiers
/// while recording (Escape cancels, an invalid combo beeps).
struct ShortcutRecorder: View {
    @ObservedObject var shortcutStore: ShortcutStore

    @State private var isRecording = false
    @State private var liveModifiers: NSEvent.ModifierFlags = []
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                HStack(spacing: 6) {
                    if isRecording {
                        ForEach(liveModifierSymbols, id: \.self) { KeyCapView(symbol: $0) }
                        Text("Recording…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(shortcutStore.shortcut.symbols.enumerated()), id: \.offset) { _, symbol in
                            KeyCapView(symbol: symbol)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(minWidth: 210, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isRecording ? Color.accentColor : Color.secondary.opacity(0.25),
                                lineWidth: isRecording ? 2 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            if isRecording {
                Button {
                    stopRecording()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "Cancel"))
            } else {
                Button {
                    shortcutStore.reset()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(String(localized: "Reset to default"))
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var liveModifierSymbols: [String] {
        var symbols: [String] = []
        if liveModifiers.contains(.control) { symbols.append("⌃") }
        if liveModifiers.contains(.option) { symbols.append("⌥") }
        if liveModifiers.contains(.shift) { symbols.append("⇧") }
        if liveModifiers.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        liveModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return nil
            }
            if event.keyCode == KeyCode.escape {
                stopRecording()
                return nil
            }
            if let shortcut = HotKeyShortcut(event: event) {
                shortcutStore.update(shortcut)
                stopRecording()
                return nil
            }
            // Needs at least one modifier — reject with the standard system beep.
            NSSound.beep()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        liveModifiers = []
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
