import SwiftUI

/// The jellyfish accent, swimming.
///
/// A jellyfish does not travel at a constant speed, and it does not travel
/// sideways. It contracts its bell in a quick squeeze, and *that squeeze is
/// the propulsion* — it lifts, then sinks back while the bell reopens and the
/// tentacles catch up. Translating the supplied artwork along a path would
/// miss all of that and read as a sticker being dragged around, so the mark is
/// rebuilt here as a parametric path from the same geometry as
/// `Lagoon_Jellyfish_Accent.svg` and deformed per frame.
///
/// Four things are coupled, and the coupling is the whole effect:
///
/// - **The beat pushes up.** Lift takes the shape of the contraction, so the
///   animal rises quickly while it squeezes and sinks slowly while it does
///   not. It holds height only while working for it — the way someone treading
///   water goes under the moment they stop.
/// - **Over a beat, lift and sink cancel.** Where it actually ends up is a
///   separate, far slower drift, so it hovers instead of climbing away.
/// - **The bell deforms rather than scales.** Contracting narrows it, draws it
///   taller, and tucks the rim inward; relaxing lets it spread back out.
/// - **The tentacles lag.** They answer a slightly *earlier* moment than the
///   bell, so they stream out straight behind a surge and curl back under
///   during the sink.
///
/// Everything is a closed-form function of time — nothing integrates frame to
/// frame — so the motion cannot drift, desynchronise, or depend on when the
/// view happened to appear.
struct JellyfishSwimLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where each animal hovers, in unit coordinates of the containing space.
    ///
    /// Two constraints shape these. The centre column belongs to the lockup
    /// and the form, so nothing crosses it — an animal surfacing from behind a
    /// button reads as a glitch, not as depth. And every drift stays inside
    /// the 5% the TV may swallow to overscan, body width included, because a
    /// jellyfish half-eaten by the bezel is worse than no jellyfish.
    private static let swimmers: [Swimmer] = [
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

    var body: some View {
        if reduceMotion {
            // Motion is the entire point of this layer, so there is nothing to
            // slow down — it steps back to the supplied artwork, still.
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
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let seconds = timeline.date.timeIntervalSinceReferenceDate
                    for swimmer in Self.swimmers {
                        swimmer.draw(in: &context, size: size, seconds: seconds)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// One animal: where it hovers, how fast it beats, and how big it is.
private struct Swimmer {
    /// Centre of its slow drift, in unit coordinates.
    let home: CGPoint
    /// Half-extent of that drift, in unit coordinates.
    let wander: CGSize
    /// Seconds for a full drift on each axis. Deliberately long and mutually
    /// prime-ish, so the animal never retraces the same figure.
    let wanderPeriod: CGSize
    /// Seconds per bell beat.
    let period: Double
    /// Offset into the beat, so they are never in unison.
    let phase: Double
    let scale: Double
    let opacity: Double

    /// How far one beat lifts the animal, as a share of its own height.
    private var liftShare: Double { 0.55 }
    /// The lift peaks a moment after the squeeze does — the body carries
    /// upward before gravity takes it back.
    private var liftLag: Double { 0.06 }
    /// How far behind the bell the tentacles answer, in beats.
    private var tentacleLag: Double { 0.16 }
    /// Share of the beat spent contracting. A real bell squeezes fast and
    /// reopens slowly, which is what makes the motion read as alive.
    private var squeeze: Double { 0.3 }
    /// How far the body may lean out of upright, either way.
    private var maximumTilt: Double { 0.22 }

    func draw(in context: inout GraphicsContext, size: CGSize, seconds: Double) {
        let beats = seconds / period + phase
        let beat = beats.truncatingRemainder(dividingBy: 1)
        let contraction = Self.contraction(of: beat, squeeze: squeeze)
        let trail = Self.thrust(of: beat - tentacleLag, squeeze: squeeze)

        let side = min(size.width, size.height)
        let drawn = side * 0.115 * scale

        // The beat is the propulsion, and it pushes *up*. The lift takes the
        // shape of the contraction, so it rises quickly on the squeeze and
        // sinks back slowly while the bell reopens — the animal only holds
        // height while it is working for it, and gravity has it the rest of
        // the time. Over a beat the two cancel, so it treads water rather than
        // climbing off the screen; where it actually goes is the slow drift.
        let lift = drawn * liftShare * Self.contraction(of: beat - liftLag, squeeze: squeeze)

        let sway = seconds / wanderPeriod.width * .pi * 2 + phase * .pi * 2
        let rise = seconds / wanderPeriod.height * .pi * 2 + phase * .pi * 2
        let position = CGPoint(
            x: (home.x + wander.width * sin(sway)) * size.width,
            y: (home.y + wander.height * sin(rise)) * size.height - lift
        )

        // Upright, always, leaning only into the sideways drift — the rate of
        // that drift is its cosine. A bell turned fully into its heading swims
        // flat on its side, which reads as a dead one, and at that angle the
        // accent stops being recognisable as the mark at all.
        let tilt = maximumTilt * cos(sway)

        var body = context
        body.translateBy(x: position.x, y: position.y)
        body.rotate(by: .radians(tilt))
        body.scaleBy(x: drawn / 256, y: drawn / 256)
        body.translateBy(x: -128, y: -140)

        let ink = GraphicsContext.Shading.color(Color.lagoonAqua.opacity(opacity))
        body.stroke(
            JellyfishGeometry.bell(contraction: contraction),
            with: ink,
            style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
        )
        body.stroke(
            JellyfishGeometry.tentacles(contraction: contraction, trail: trail),
            with: ink,
            style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
        )
    }

    /// 0 relaxed, 1 fully contracted. Two cosine halves, so the rate is zero
    /// at both ends of the beat and the loop never shows a seam.
    static func contraction(of phase: Double, squeeze: Double) -> Double {
        var phase = phase.truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        if phase < squeeze {
            return 0.5 - 0.5 * cos(.pi * phase / squeeze)
        }
        return 0.5 + 0.5 * cos(.pi * (phase - squeeze) / (1 - squeeze))
    }

    /// How hard the bell is pushing right now, 0...1. Only the contracting
    /// half of the beat produces any.
    static func thrust(of phase: Double, squeeze: Double) -> Double {
        var phase = phase.truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        guard phase < squeeze else { return 0 }
        return sin(.pi * phase / squeeze)
    }
}

/// The mark's geometry, rebuilt so it can be deformed.
///
/// Coordinates are the SVG's own 256x280 space and the control points are its
/// control points, so a still frame at rest is the supplied artwork rather than
/// a lookalike.
enum JellyfishGeometry {
    /// Apex, rim, and the widest point of the bell at rest.
    private static let apex: CGFloat = 42
    private static let rim: CGFloat = 188
    private static let axis: CGFloat = 128

    /// Contracting narrows the bell, draws it taller, and tucks the rim under.
    private static func deform(_ point: CGPoint, contraction: Double) -> CGPoint {
        let narrow = 1 - 0.22 * contraction
        let stretch = 1 + 0.15 * contraction
        return CGPoint(
            x: axis + (point.x - axis) * narrow,
            y: rim - (rim - point.y) * stretch
        )
    }

    static func bell(contraction: Double) -> Path {
        let d = { deform($0, contraction: contraction) }
        // The rim tucks further in than the body narrows — the lip curls under
        // the bell on a squeeze instead of simply shrinking with it.
        let tuck = 14 * contraction
        let leftRim = CGPoint(x: d(CGPoint(x: 88, y: rim)).x + tuck, y: d(CGPoint(x: 88, y: rim)).y)
        let rightRim = CGPoint(x: d(CGPoint(x: 168, y: rim)).x - tuck, y: d(CGPoint(x: 168, y: rim)).y)

        var path = Path()
        path.move(to: d(CGPoint(x: axis, y: apex)))
        path.addCurve(
            to: d(CGPoint(x: 38, y: 139)),
            control1: d(CGPoint(x: 72, y: apex)),
            control2: d(CGPoint(x: 38, y: 82))
        )
        path.addCurve(
            to: leftRim,
            control1: d(CGPoint(x: 38, y: 169)),
            control2: d(CGPoint(x: 58, y: rim))
        )
        path.addLine(to: rightRim)
        path.addCurve(
            to: d(CGPoint(x: 218, y: 139)),
            control1: d(CGPoint(x: 198, y: rim)),
            control2: d(CGPoint(x: 218, y: 169))
        )
        path.addCurve(
            to: d(CGPoint(x: axis, y: apex)),
            control1: d(CGPoint(x: 218, y: 82)),
            control2: d(CGPoint(x: 184, y: apex))
        )
        path.closeSubpath()
        return path
    }

    /// The four tentacles, as the SVG draws them, plus the two things that
    /// make them look attached to a living animal: they hang from wherever the
    /// deformed rim now is, and they answer the *previous* moment's thrust —
    /// streaming out straight behind a surge, gathering and curling under while
    /// the animal coasts.
    static func tentacles(contraction: Double, trail: Double) -> Path {
        let strands: [(start: CGFloat, c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
            (76, CGPoint(x: 76, y: 220), CGPoint(x: 61, y: 226), CGPoint(x: 61, y: 254)),
            (108, CGPoint(x: 108, y: 220), CGPoint(x: 96, y: 229), CGPoint(x: 96, y: 266)),
            (148, CGPoint(x: 148, y: 223), CGPoint(x: 160, y: 230), CGPoint(x: 160, y: 264)),
            (180, CGPoint(x: 180, y: 218), CGPoint(x: 194, y: 226), CGPoint(x: 194, y: 250)),
        ]

        var path = Path()
        for strand in strands {
            let anchor = deform(CGPoint(x: strand.start, y: rim), contraction: contraction)
            // Streamlined and stretched behind on thrust; shorter, wider and
            // more curled on the coast.
            let stretch = 1 + 0.22 * trail
            let curl = 1 - 0.55 * trail
            let splay = 1 + 0.18 * (1 - trail)

            let shape = { (point: CGPoint) -> CGPoint in
                CGPoint(
                    x: anchor.x + (point.x - strand.start) * curl * splay,
                    y: anchor.y + (point.y - rim) * stretch
                )
            }
            path.move(to: anchor)
            path.addCurve(
                to: shape(strand.end),
                control1: shape(strand.c1),
                control2: shape(strand.c2)
            )
        }
        return path
    }
}
