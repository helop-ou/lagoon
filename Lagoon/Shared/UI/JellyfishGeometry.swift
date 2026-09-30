import SwiftUI

struct Swimmer {
    /// Centre of its slow drift, in unit coordinates.
    let home: CGPoint
    /// Half-extent of that drift, in unit coordinates.
    let wander: CGSize
    /// Seconds per drift on each axis; long and roughly coprime so it never retraces.
    let wanderPeriod: CGSize
    /// Seconds per bell beat.
    let period: Double
    /// Offset into the beat, so they are never in unison.
    let phase: Double
    let scale: Double
    let opacity: Double

    /// How far one beat lifts the animal, as a share of its own height.
    private var liftShare: Double { 0.55 }
    /// The lift peaks just after the squeeze.
    private var liftLag: Double { 0.06 }
    /// How far behind the bell the tentacles answer, in beats.
    static let tentacleLag: Double = 0.16
    /// Share of the beat spent contracting: squeeze fast, reopen slowly.
    static let squeeze: Double = 0.3
    /// How far the body may lean out of upright, either way.
    private var maximumTilt: Double { 0.22 }

    func draw(in context: inout GraphicsContext, size: CGSize, seconds: Double, ink accentColor: Color) {
        let beats = seconds / period + phase
        let beat = beats.truncatingRemainder(dividingBy: 1)
        let contraction = Self.contraction(of: beat, squeeze: Self.squeeze)
        let trail = Self.thrust(of: beat - Self.tentacleLag, squeeze: Self.squeeze)

        let side = min(size.width, size.height)
        let drawn = side * 0.115 * scale

        // Lift follows the contraction and cancels over a beat, so it treads
        // water; the slow drift is where it actually goes.
        let lift = drawn * liftShare * Self.contraction(of: beat - liftLag, squeeze: Self.squeeze)

        let sway = seconds / wanderPeriod.width * .pi * 2 + phase * .pi * 2
        let rise = seconds / wanderPeriod.height * .pi * 2 + phase * .pi * 2
        let position = CGPoint(
            x: (home.x + wander.width * sin(sway)) * size.width,
            y: (home.y + wander.height * sin(rise)) * size.height - lift
        )

        // Stay upright, leaning only into the sideways drift (its rate is the
        // cosine). Turned fully sideways it reads as dead.
        let tilt = maximumTilt * cos(sway)

        var body = context
        body.translateBy(x: position.x, y: position.y)
        body.rotate(by: .radians(tilt))
        body.scaleBy(x: drawn / 256, y: drawn / 256)
        body.translateBy(x: -128, y: -140)

        JellyfishGeometry.stroke(
            in: &body,
            contraction: contraction,
            trail: trail,
            with: .color(accentColor.opacity(opacity))
        )
    }

    /// 0 relaxed, 1 contracted. Two cosine halves, so the loop has no seam.
    static func contraction(of phase: Double, squeeze: Double) -> Double {
        var phase = phase.truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        if phase < squeeze {
            return 0.5 - 0.5 * cos(.pi * phase / squeeze)
        }
        return 0.5 + 0.5 * cos(.pi * (phase - squeeze) / (1 - squeeze))
    }

    /// 0...1, non-zero only while contracting.
    static func thrust(of phase: Double, squeeze: Double) -> Double {
        var phase = phase.truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
        guard phase < squeeze else { return 0 }
        return sin(.pi * phase / squeeze)
    }
}

/// The mark's geometry in the SVG's own 256x280 space and control points,
/// so a frame at rest is the supplied artwork.
enum JellyfishGeometry {
    /// Scale a context to this before calling `stroke`.
    static let canvas = CGSize(width: 256, height: 280)

    /// Shared by the swim layer and the theme bloom, so the mark has one
    /// line weight everywhere.
    static func stroke(
        in context: inout GraphicsContext,
        contraction: Double,
        trail: Double,
        with ink: GraphicsContext.Shading
    ) {
        context.stroke(
            bell(contraction: contraction),
            with: ink,
            style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            tentacles(contraction: contraction, trail: trail),
            with: ink,
            style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
        )
    }

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
        // The rim tucks in further than the body narrows, so the lip curls under.
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

    /// Tentacles hang from the deformed rim and follow the previous moment's
    /// thrust: straight behind a surge, curled while coasting.
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
