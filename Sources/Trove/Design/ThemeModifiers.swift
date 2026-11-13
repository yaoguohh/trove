import SwiftUI

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
