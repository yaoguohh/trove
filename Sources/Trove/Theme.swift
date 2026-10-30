import AppKit
import QuartzCore
import SwiftUI

/// Single source of truth for Trove's look. The palette is "anthracite" (borrowed from Tern's theme of
/// the same name): cool blue-gray neutrals with one warm ember accent. Everything is expressed as
/// ladders — surface, text, line, accent-alpha — so every state change is "one step up the ladder"
/// and the UI stays coherent. Trove is dark-only by design (AppDelegate pins `.darkAqua`), so each
/// token has exactly one value; there are no light/dark branches anywhere in the views.
enum Theme {
    /// Surfaces step lighter as they rise (Tern's rule): chrome → coal → card → raise.
    enum Surface {
        /// Status menu, peek bubble, "window frame" level — the darkest opaque surface.
        static let chrome = Color(hex: 0x0F1114)
        /// Ground: inspect window background.
        static let coal = Color(hex: 0x121419)
        /// Cards and controls. Opaque so a card fully occludes the blurred desktop behind the glass.
        static let card = Color(hex: 0x1A1E25)
        /// Hovered / selected card.
        static let raise = Color(hex: 0x252932)
    }

    /// Four text tiers, not two.
    enum Text {
        static let t1 = Color(hex: 0xD4D8E4)   // primary
        static let t2 = Color(hex: 0x9CA3B5)   // secondary
        static let t3 = Color(hex: 0x6B7280)   // labels / icons / footers
        static let t4 = Color(hex: 0x4D5561)   // placeholders / separators
    }

    /// White-alpha ladder for hover fills and hairlines. A hairline is a 1pt stroke of `l2`, never a
    /// border, so it never shifts layout.
    enum Line {
        static let l1 = Color.white.opacity(0.07)   // hover fill
        static let l2 = Color.white.opacity(0.10)   // hairline
        static let l3 = Color.white.opacity(0.15)   // strong hairline (active control)
        static let l4 = Color.white.opacity(0.24)   // separators / grips
        /// Top inner highlight on raised surfaces (Tern's `--glass-hi` in dark).
        static let glassHi = Color.white.opacity(0.05)
    }

    /// The one accent. Used at fixed alpha steps for fills and rings; never a second brand hue.
    static let accent = Color(hex: 0xE8734A)        // ember
    static let accentDim = Color(hex: 0xB5583A)
    enum Accent {
        static let fill = Theme.accent.opacity(0.16)       // selected chip / primary button fill
        static let fillHover = Theme.accent.opacity(0.22)
        static let ring = Theme.accent.opacity(0.18)       // focus / selection outer ring
        static let hairline = Theme.accent.opacity(0.22)
        static let highlight = Theme.accent.opacity(0.28)  // search-match highlight
    }

    /// Semantic colors are independent of the accent.
    enum Semantic {
        static let ok = Color(hex: 0x7FB069)
        static let warn = Color(hex: 0xE89C4A)
        static let bad = Color(hex: 0xD9534F)
        static let link = Color(hex: 0x6BA3D4)
    }

    /// Four fixed radii; nothing scales its radius with its size.
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 14
        static let panel: CGFloat = 16
    }

    /// Two curves only. `ease` moves color/opacity (150ms); `out` moves position/scale/size
    /// (200–450ms). Entrances are scale 0.97 + a 3–6pt nudge; presses are scale 0.97. Every helper
    /// returns nil (no animation) when the system asks for reduced motion.
    enum Motion {
        static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        static var ease: Animation? { ease(0.15) }
        static func ease(_ duration: Double) -> Animation? {
            reduce ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: duration)
        }
        static func out(_ duration: Double = 0.2) -> Animation? {
            reduce ? nil : .timingCurve(0.16, 1, 0.3, 1, duration: duration)
        }
        /// Gesture-driven motion (drag reorder) keeps a physical spring.
        static func spring(response: Double, dampingFraction: Double) -> Animation? {
            reduce ? nil : .spring(response: response, dampingFraction: dampingFraction)
        }
        /// For `NSAnimationContext` durations.
        static func seconds(_ duration: Double) -> Double { reduce ? 0 : duration }
        static var easeTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1) }
        static var outTiming: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1) }

        static let pressScale: CGFloat = 0.97
        static let popScale: CGFloat = 0.97
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Shared motion primitives

/// Press feedback for every plain button: scale 0.97 over 120ms (Tern's `:active`).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Theme.Motion.pressScale : 1)
            .animation(Theme.Motion.ease(0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Tern's `popIn`: scale 0.97 + a 3pt nudge resolving over ~180ms on the `out` curve. Plays on
/// appear and again whenever `trigger` changes (a re-summon). `fade` adds opacity for content that
/// isn't already faded in by its window; `nudge` is the start offset (negative = from above).
struct PopInModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let duration: Double
    let fade: Bool
    let nudge: CGFloat
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : Theme.Motion.popScale)
            .offset(y: shown ? 0 : nudge)
            .opacity(fade && !shown ? 0 : 1)
            .onAppear(perform: play)
            .onChange(of: trigger) { play() }
    }

    private func play() {
        // Two transactions: reset without animation, then animate in on the next turn of the run
        // loop — a same-transaction false→true collapses to a no-op.
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { shown = false }
        DispatchQueue.main.async {
            withAnimation(Theme.Motion.out(duration)) { shown = true }
        }
    }
}

extension View {
    func popIn<Trigger: Equatable>(trigger: Trigger, duration: Double = 0.18, fade: Bool = false, nudge: CGFloat = -3) -> some View {
        modifier(PopInModifier(trigger: trigger, duration: duration, fade: fade, nudge: nudge))
    }

    func popIn(duration: Double = 0.18, fade: Bool = false, nudge: CGFloat = -3) -> some View {
        modifier(PopInModifier(trigger: 0, duration: duration, fade: fade, nudge: nudge))
    }
}

/// Tern's working-state shimmer: a soft band of brighter text sweeping left→right every 2s. Applied
/// to text that is a placeholder for content still loading. No-op under reduced motion.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -0.6

    func body(content: Content) -> some View {
        content
            .overlay {
                if !Theme.Motion.reduce {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Theme.Text.t1.opacity(0.75), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geo.size.width * 0.6)
                        .offset(x: phase * geo.size.width)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard !Theme.Motion.reduce else { return }
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    phase = 1.2
                }
            }
    }
}

extension View {
    @ViewBuilder
    func shimmer(_ active: Bool) -> some View {
        if active {
            modifier(ShimmerModifier())
        } else {
            self
        }
    }
}
