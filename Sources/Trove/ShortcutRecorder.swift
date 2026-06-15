import AppKit
import SwiftUI

/// A compact rounded key-cap badge, e.g. ⇧ ⌘ V — sized to sit inline on a menu row.
struct KeyCapView: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11.5, weight: .medium, design: .rounded))
            .frame(minWidth: 15, minHeight: 19)
            .padding(.horizontal, 3)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
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
        HStack(spacing: 6) {
            // The shortcut shown as a compact pill of key caps; click to (re)record. While recording it
            // shows the live-held modifiers, or "Recording…" until the first modifier goes down.
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                HStack(spacing: 3) {
                    if isRecording {
                        if liveModifierSymbols.isEmpty {
                            Text("Recording…")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        } else {
                            ForEach(Array(liveModifierSymbols.enumerated()), id: \.offset) { _, symbol in
                                KeyCapView(symbol: symbol)
                            }
                        }
                    } else {
                        ForEach(Array(shortcutStore.shortcut.symbols.enumerated()), id: \.offset) { _, symbol in
                            KeyCapView(symbol: symbol)
                        }
                    }
                }
                // Fixed min size so the pill doesn't jump between the idle chips and the recording
                // prompt; a clean accent border (no filled blob) marks the active state.
                .frame(minWidth: 58, minHeight: 25)
                .padding(.horizontal, 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isRecording ? Color.accentColor : Color.primary.opacity(0.14),
                                      lineWidth: isRecording ? 1.5 : 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            // One trailing affordance: cancel while recording, otherwise reset to the default shortcut.
            Button {
                isRecording ? stopRecording() : shortcutStore.reset()
            } label: {
                Image(systemName: isRecording ? "xmark.circle.fill" : "arrow.counterclockwise")
                    .font(.system(size: isRecording ? 12 : 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRecording ? String(localized: "Cancel") : String(localized: "Reset to default"))
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
