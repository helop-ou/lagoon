import SwiftUI

/// The moment a theme is chosen (HEL-173): a soft bloom of the new accent
/// swells from the middle of the screen and lets go, and a handful of
/// petals drift up through it. Under two seconds, never in the way, and
/// over before the eye is done with it. Nothing here is interactive: the
/// overlay ignores touches and focus, and the UI beneath has already taken
/// its new colours by the time the bloom fades.
///
/// Reduce Motion keeps the bloom's fade and drops the petals and the swell,
/// so the change is still announced without anything moving across the
/// screen.
struct ThemeBloomOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bloom: Bloom?

    private struct Bloom: Equatable {
        let accent: Color
        let startedAt: Date
        let seed: Int
    }

    private static let duration: TimeInterval = 1.7

    var body: some View {
        ZStack {
            if let bloom {
                TimelineView(.animation) { timeline in
                    let progress = min(1, timeline.date.timeIntervalSince(bloom.startedAt) / Self.duration)
                    ThemeBloomFrame(
                        accent: bloom.accent,
                        progress: progress,
                        seed: bloom.seed,
                        reduceMotion: reduceMotion
                    )
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: ThemeStore.shared.selectionCount) { _, count in
            bloom = Bloom(accent: Theme.accent, startedAt: .now, seed: count)
            Task {
                try? await Task.sleep(for: .seconds(Self.duration))
                if bloom?.seed == count {
                    withAnimation(.easeOut(duration: Motion.fast)) { bloom = nil }
                }
            }
        }
    }
}

/// One frame of the bloom, drawn for a progress between 0 and 1.
private struct ThemeBloomFrame: View {
    let accent: Color
    let progress: Double
    let seed: Int
    let reduceMotion: Bool

    /// The bloom swells for the first half and fades through the second.
    private var swell: Double {
        reduceMotion ? 1 : Self.easeOut(min(1, progress / 0.55))
    }

    private var glowOpacity: Double {
        let rise = Self.easeOut(min(1, progress / 0.25))
        let fall = 1 - Self.easeIn(max(0, (progress - 0.45) / 0.55))
        return (reduceMotion ? 0.35 : 0.55) * rise * fall
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let reach = max(size.width, size.height)
            ZStack {
                RadialGradient(
                    colors: [accent.opacity(glowOpacity), accent.opacity(glowOpacity * 0.35), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: reach * (0.25 + 0.75 * swell)
                )
                if !reduceMotion {
                    Canvas { context, canvasSize in
                        drawPetals(in: &context, size: canvasSize)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    /// A dozen petals from the lower half of the screen, each on its own
    /// schedule, drifting up with a little sway and a slow turn, fading as
    /// they go. Positions come from the seed, so one bloom's petals are not
    /// the next one's.
    private func drawPetals(in context: inout GraphicsContext, size: CGSize) {
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed &+ 7))
        let count = 12
        let petalBase = max(size.width, size.height) * 0.014
        for _ in 0..<count {
            let startX = Double.random(in: 0.08...0.92, using: &generator)
            let startY = Double.random(in: 0.55...1.05, using: &generator)
            let delay = Double.random(in: 0...0.35, using: &generator)
            let climb = Double.random(in: 0.35...0.6, using: &generator)
            let sway = Double.random(in: -0.06...0.06, using: &generator)
            let scale = Double.random(in: 0.7...1.4, using: &generator)
            let spin = Double.random(in: -1.2...1.2, using: &generator)

            let local = max(0, min(1, (progress - delay) / (1 - delay)))
            guard local > 0 else { continue }
            let travel = Self.easeOut(local)
            let x = (startX + sway * sin(local * .pi * 2)) * size.width
            let y = (startY - climb * travel) * size.height
            let opacity = 0.55 * sin(local * .pi)
            let width = petalBase * scale
            let height = width * 1.6

            var petal = context
            petal.translateBy(x: x, y: y)
            petal.rotate(by: .radians(spin * local + sway * 4))
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            petal.fill(Path(ellipseIn: rect), with: .color(accent.opacity(opacity)))
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
    private static func easeIn(_ t: Double) -> Double { t * t * t }
}

/// A small deterministic generator, so the petals' layout is a function of
/// the bloom and not of the frame it is drawn in.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
