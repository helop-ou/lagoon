import SwiftUI

/// The jellyfish accent, swimming. The mark is rebuilt as a path from
/// `Lagoon_Jellyfish_Accent.svg` and deformed per frame, because moving the
/// artwork whole reads as a dragged sticker. Closed-form in time, so it
/// cannot drift.
struct JellyfishSwimLayer: View {
    /// Which stretch of water is free on the current onboarding screen.
    enum School {
        /// Flanking a narrow centred column.
        case flanking
        /// Clear of a horizontal rail across the middle.
        case besideTheRail

        /// Nothing crosses the screen's content, and every drift, lift
        /// included, stays inside the 5% TV overscan margin.
        var swimmers: [Swimmer] {
            switch self {
            case .flanking:
                [
                    Swimmer(
                        home: CGPoint(x: 0.18, y: 0.50),
                        wander: CGSize(width: 0.035, height: 0.10),
                        wanderPeriod: CGSize(width: 34, height: 47),
                        period: 3.6,
                        phase: 0,
                        scale: 1.0,
                        opacity: 0.30
                    ),
                    Swimmer(
                        home: CGPoint(x: 0.82, y: 0.36),
                        wander: CGSize(width: 0.030, height: 0.09),
                        wanderPeriod: CGSize(width: 41, height: 55),
                        period: 4.4,
                        phase: 0.45,
                        scale: 0.78,
                        opacity: 0.22
                    ),
                    Swimmer(
                        home: CGPoint(x: 0.85, y: 0.78),
                        wander: CGSize(width: 0.028, height: 0.07),
                        wanderPeriod: CGSize(width: 29, height: 38),
                        period: 5.2,
                        phase: 0.75,
                        scale: 0.60,
                        opacity: 0.16
                    ),
                ]
            case .besideTheRail:
                // The rail may span the middle third's full width; keep above and below it.
                [
                    Swimmer(
                        home: CGPoint(x: 0.15, y: 0.20),
                        wander: CGSize(width: 0.030, height: 0.055),
                        wanderPeriod: CGSize(width: 34, height: 47),
                        period: 3.6,
                        phase: 0,
                        scale: 0.82,
                        opacity: 0.26
                    ),
                    Swimmer(
                        home: CGPoint(x: 0.86, y: 0.22),
                        wander: CGSize(width: 0.026, height: 0.050),
                        wanderPeriod: CGSize(width: 41, height: 55),
                        period: 4.4,
                        phase: 0.45,
                        scale: 0.70,
                        opacity: 0.20
                    ),
                    Swimmer(
                        home: CGPoint(x: 0.80, y: 0.89),
                        wander: CGSize(width: 0.028, height: 0.035),
                        wanderPeriod: CGSize(width: 29, height: 38),
                        period: 5.2,
                        phase: 0.75,
                        scale: 0.58,
                        opacity: 0.15
                    ),
                ]
            }
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var school: School = .flanking

    var body: some View {
        if reduceMotion {
            // Reduce Motion: show the artwork still.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LagoonJellyfishAccent()
                        .padding(.trailing, Metrics.screenGutter + Metrics.Space.l)
                        .padding(.bottom, Metrics.screenGutter + Metrics.Space.l)
                }
            }
        } else {
            // Read in the body so Observation tracks the theme; the Canvas
            // closure only sees the resolved color.
            let ink = Theme.accent
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    for swimmer in school.swimmers {
                        swimmer.draw(in: &context, size: size, seconds: seconds, ink: ink)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}
