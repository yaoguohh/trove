import AppKit
import QuartzCore
import SwiftUI

/// Single source of truth for Trove's look: every color, radius, shadow and motion value a view
/// uses is a token here (docs/DESIGN.md has the rules and the few exceptions). The palette is
/// "anthracite", from the Tern design system: cool blue-gray neutrals with one warm ember accent,
/// expressed as ladders — surface, text, line, accent-alpha — so every state change is one step up a
/// ladder. Trove is dark-only (AppDelegate pins `.darkAqua`), so each token has exactly one value.
enum Theme {
    /// Surfaces step lighter as they rise: coal → card → raise.
    enum Surface {
        /// Ground: inspector background.
        static let coal = Color(hex: 0x121419)
        /// Cards and controls. Opaque so a card fully occludes the blurred desktop behind the glass.
        static let card = Color(hex: 0x1A1E25)
        /// Hovered / selected card.
        static let raise = Color(hex: 0x252932)
    }

    /// Three text tiers.
    enum Text {
        static let t1 = Color(hex: 0xD4D8E4)   // primary
        static let t2 = Color(hex: 0x9CA3B5)   // secondary
        static let t3 = Color(hex: 0x6B7280)   // labels / icons / footers
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
    enum Accent {
        static let fill = Theme.accent.opacity(0.16)       // selected chip / primary button fill
        static let ring = Theme.accent.opacity(0.18)       // focus / selection outer ring
        static let hairline = Theme.accent.opacity(0.22)
        static let highlight = Theme.accent.opacity(0.28)  // search-match highlight
    }

    /// Semantic colors are independent of the accent.
    enum Semantic {
        static let warn = Color(hex: 0xE89C4A)
    }

    /// The identity hues: anthracite's bright terminal set, balanced against the dark card surface.
    /// Pinboards pick one by name; a source app without a readable icon gets one by its name's hash.
    /// Never used for chrome or state — that is the accent's job.
    enum Hue {
        static let red = Color(hex: 0xEF7A72)
        static let orange = Theme.accent
        static let yellow = Color(hex: 0xF0D88A)
        static let green = Color(hex: 0x9CC98A)
        static let teal = Color(hex: 0x8CD0C2)
        static let blue = Color(hex: 0x9CC2E8)
        static let purple = Color(hex: 0xD0AADE)
        /// Only for pinboards created before v1.2.0, whose stored color name is "pink".
        static let pink = Color(hex: 0xE2A3C0)

        static let all = [red, orange, yellow, green, teal, blue, purple]
    }

    /// Fixed radii, smallest to largest. App-style icons are the one exception: they use the macOS
    /// icon squircle, whose radius is a fraction of the icon's size (`icon(size:)`).
    enum Radius {
        static let keycap: CGFloat = 4
        static let chip: CGFloat = 6
        static let control: CGFloat = 8
        static let media: CGFloat = 10      // an image inset in a card
        static let card: CGFloat = 14
        static let panel: CGFloat = 16

        static func icon(size: CGFloat) -> CGFloat { size * 0.22 }
    }

    /// Shadows by elevation. Everything that casts one uses one of these.
    enum Shadow {
        static let rest = ShadowStyle(opacity: 0.14, radius: 8, y: 4)        // a card at rest
        static let lifted = ShadowStyle(opacity: 0.26, radius: 18, y: 8)     // hovered / selected / dragged
        static let floating = ShadowStyle(opacity: 0.55, radius: 16, y: 6)   // the peek bubble

        /// A small app-style badge (source icon, favicon), proportional to its size.
        static func badge(size: CGFloat) -> ShadowStyle {
            ShadowStyle(opacity: 0.12, radius: size * 0.13, y: size * 0.06)
        }
    }

    /// Two curves only. `ease` moves color/opacity; `out` moves position/scale/size. Entrances are
    /// `scale` + a 3–6pt nudge; presses are `scale`. Every helper returns nil (no animation) when the
    /// system asks for reduced motion.
    enum Motion {
        static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        /// The only durations in the app, in seconds.
        enum Duration {
            static let press = 0.12
            static let fade = 0.15      // color / opacity; a window fading out
            static let appear = 0.18    // entrances: a window fading in, popIn
            static let move = 0.2       // position / scale / size
            static let reflow = 0.22    // cards entering / leaving a list
            static let slow = 0.3       // long travel: scroll-to, the empty state
        }

        static var ease: Animation? { ease(Duration.fade) }
        static func ease(_ duration: Double) -> Animation? {
            reduce ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: duration)
        }
        static func out(_ duration: Double = Duration.move) -> Animation? {
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

        /// Pressed buttons and arriving content start at this scale.
        static let scale: CGFloat = 0.97
    }
}

struct ShadowStyle {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat
}

extension View {
    func shadow(_ style: ShadowStyle) -> some View {
        shadow(color: .black.opacity(style.opacity), radius: style.radius, x: 0, y: style.y)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

// MARK: - Shared motion primitives

/// Press feedback for every plain button (Tern's `:active`).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Theme.Motion.scale : 1)
            .animation(Theme.Motion.ease(Theme.Motion.Duration.press), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

/// Tern's `popIn`: `Motion.scale` + a 3pt nudge resolving on the `out` curve. Plays on
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
            .scaleEffect(shown ? 1 : Theme.Motion.scale)
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
    func popIn<Trigger: Equatable>(trigger: Trigger, duration: Double = Theme.Motion.Duration.appear, fade: Bool = false, nudge: CGFloat = -3) -> some View {
        modifier(PopInModifier(trigger: trigger, duration: duration, fade: fade, nudge: nudge))
    }

    func popIn(duration: Double = Theme.Motion.Duration.appear, fade: Bool = false, nudge: CGFloat = -3) -> some View {
        modifier(PopInModifier(trigger: 0, duration: duration, fade: fade, nudge: nudge))
    }
}

/// Tern's working-state shimmer: a soft band of brighter text sweeping left→right every `period`
/// seconds. Applied to text that is a placeholder for content still loading. No-op under reduced motion.
struct ShimmerModifier: ViewModifier {
    private static let period = 2.0
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
                withAnimation(.linear(duration: Self.period).repeatForever(autoreverses: false)) {
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
