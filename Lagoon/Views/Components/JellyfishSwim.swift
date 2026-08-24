import SwiftUI

/// The jellyfish accent, swimming.
///
/// A jellyfish does not travel at a constant speed. It contracts its bell in a
/// quick squeeze, and *that squeeze is the propulsion* — it surges, then coasts
/// with the bell relaxing open while the tentacles catch up. Translating the
/// supplied artwork along a path would miss all of that and read as a sticker
/// being dragged around, so the mark is rebuilt here as a parametric path from
/// the same geometry as `Lagoon_Jellyfish_Accent.svg` and deformed per frame.
///
/// Three things are coupled, and the coupling is the whole effect:
///
/// - **Contraction drives distance.** Forward travel is the integral of the
///   bell's contraction rate, so the animal only gains ground while squeezing.
///   The glide term adds a little carried momentum so it does not stall dead
///   between beats.
/// - **The bell deforms rather than scales.** Contracting narrows it, draws it
///   taller, and tucks the rim inward; relaxing lets it spread back out.
/// - **The tentacles lag.** They answer a slightly *earlier* moment than the
///   bell, so they stream out straight behind a surge and curl back under
///   during the coast.
///
/// Everything is a closed-form function of time — nothing integrates frame to
/// frame — so the motion cannot drift, desynchronise, or depend on when the
/// view happened to appear.
struct JellyfishSwimLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where each animal loops, in unit coordinates of the containing space.
    ///
    /// Two constraints shape these. The centre column belongs to the lockup
    /// and the form, so nothing crosses it — an animal surfacing from behind a
    /// button reads as a glitch, not as depth. And every loop stays inside the
    /// 5% the TV may swallow to overscan, body width included, because a
    /// jellyfish half-eaten by the bezel is worse than no jellyfish.
    private static let swimmers: [Swimmer] = [
        Swimmer(
            centre: CGPoint(x: 0.18, y: 0.54),
            drift: CGSize(width: 0.08, height: 0.28),
            lobes: CGSize(width: 1, height: 2),
            period: 3.1,
            phase: 0,
            scale: 1.0,
            opacity: 0.30
        ),
        Swimmer(
            centre: CGPoint(x: 0.82, y: 0.38),
            drift: CGSize(width: 0.09, height: 0.24),
            lobes: CGSize(width: 2, height: 1),
            period: 3.9,
            phase: 0.45,
            scale: 0.78,
            opacity: 0.22
        ),
        Swimmer(
            centre: CGPoint(x: 0.85, y: 0.80),
            drift: CGSize(width: 0.07, height: 0.08),
            lobes: CGSize(width: 1, height: 2),
            period: 4.6,
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

/// One animal: where it loops, how fast it beats, and how big it is.
private struct Swimmer {
    /// Centre of its loop, in unit coordinates.
    let centre: CGPoint
    /// Half-extent of the loop, in unit coordinates.
    let drift: CGSize
    /// Lissajous lobe counts. Unequal values make the loop a figure rather
    /// than an ellipse, so the animal is rarely on the same heading twice.
    let lobes: CGSize
    /// Seconds per bell beat.
    let period: Double
    /// Offset into the beat, so they are never in unison.
    let phase: Double
    let scale: Double
    let opacity: Double

    /// Loop distance covered by one full beat. Small enough that a beat moves
    /// the animal about its own length.
    private var strideLength: Double { 0.09 }
    /// Coasting travel per beat, as a share of the surge.
    private var glideShare: Double { 0.35 }
    /// How far behind the bell the tentacles answer, in beats.
    private var tentacleLag: Double { 0.16 }
    /// Share of the beat spent contracting. A real bell squeezes fast and
    /// reopens slowly, which is what makes the motion read as alive.
    private var squeeze: Double { 0.3 }
    /// How far the body may lean out of upright, either way.
    static let maximumTilt: Double = 0.38

    func draw(in context: inout GraphicsContext, size: CGSize, seconds: Double) {
        let beats = seconds / period + phase
        let travel = travelled(at: beats)
        let position = point(along: travel, in: size)
        // Heading from the loop's tangent, sampled rather than differentiated
        // so the two stay consistent to within a hair at any step size.
        let ahead = point(along: travel + 0.0025, in: size)
        let heading = atan2(ahead.y - position.y, ahead.x - position.x)

        let contraction = Self.contraction(of: beats.truncatingRemainder(dividingBy: 1), squeeze: squeeze)
        let trail = Self.thrust(of: (beats - tentacleLag).truncatingRemainder(dividingBy: 1), squeeze: squeeze)

        // The artwork is drawn apex-up in a 256x280 box and the tangent is
        // measured apex-forward, hence the quarter turn — but only a damped
        // share of it. Turned fully into its heading the animal swims flat on
        // its side, which reads as a dead one, and at that angle the accent
        // stops being recognisable as the mark at all. A real jellyfish holds
        // its bell broadly upright and lets sideways movement be drift, so the
        // body leans into the turn and no further.
        let lean = atan2(sin(heading + .pi / 2), cos(heading + .pi / 2))
        let tilt = min(max(lean, -Self.maximumTilt), Self.maximumTilt)
        let side = min(size.width, size.height)
        let drawn = side * 0.115 * scale
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

    /// Distance along the loop, in beats' worth of travel.
    ///
    /// The surge term is the integral of the contraction rate: it climbs only
    /// while the bell is squeezing and then holds flat for the rest of the
    /// beat. The glide term is linear, and is the momentum the animal carries
    /// into the coast.
    private func travelled(at beats: Double) -> Double {
        let completed = beats.rounded(.down)
        let phase = beats - completed
        let surge = completed + (phase < squeeze
            ? Self.contraction(of: phase, squeeze: squeeze)
            : 1)
        return (surge + beats * glideShare) * strideLength
    }

    private func point(along travel: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: (centre.x + drift.width * sin(travel * .pi * 2 * lobes.width)) * size.width,
            y: (centre.y + drift.height * sin(travel * .pi * 2 * lobes.height + .pi / 3)) * size.height
        )
    }

    /// 0 relaxed, 1 fully contracted. Two cosine halves, so the rate is zero
    /// at both ends of the beat and the loop never shows a seam.
    static func contraction(of phase: Double, squeeze: Double) -> Double {
        let phase = phase < 0 ? phase + 1 : phase
        if phase < squeeze {
            return 0.5 - 0.5 * cos(.pi * phase / squeeze)
        }
        return 0.5 + 0.5 * cos(.pi * (phase - squeeze) / (1 - squeeze))
    }

    /// How hard the bell is pushing right now, 0...1. Only the contracting
    /// half of the beat produces any.
    static func thrust(of phase: Double, squeeze: Double) -> Double {
        let phase = phase < 0 ? phase + 1 : phase
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
