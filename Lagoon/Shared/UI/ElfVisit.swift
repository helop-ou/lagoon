import SwiftUI

/// An elf's visit to a snowy page: down a rope from the top of the page, a
/// look round and a wave, and back up hand over hand. Where it is depends
/// only on the time since the visit began, so any moment can be drawn.
nonisolated enum ElfVisit {
    struct Plan: Equatable {
        /// Seconds to wait before it comes down.
        let wait: TimeInterval
        /// Which side of the page it comes down.
        let onLeading: Bool
        /// Where across the side's free lane the rope hangs, 0 to 1.
        let lane: Double
        /// How far down it comes, as a share of the longest rope.
        let depth: Double
    }

    struct Pose: Equatable {
        /// 0 out of sight above the page, 1 at the end of its rope.
        let reach: Double
        /// How far to one side it has swung, in its own heights. A long
        /// rope swings no wider than a short one, or the elf would leave
        /// the page's side.
        let sway: Double
        /// 0 with both hands on the rope, 1 with one raised to wave.
        let raise: Double
        /// The raised hand's swing, -1 to 1.
        let wave: Double
        /// The legs' swing, -1 to 1.
        let kick: Double
    }

    /// Seconds before a page's first visit, and between its visits after.
    static let firstWait: ClosedRange<TimeInterval> = 20...50
    static let wait: ClosedRange<TimeInterval> = 100...220
    /// Seconds coming down, staying, and climbing back.
    static let descent: Double = 2.8
    static let stay: Double = 7
    static let climb: Double = 4.8
    static var duration: Double { descent + stay + climb }
    /// Pulls on the rope on the way up.
    static let pulls = 7
    /// How long after arriving the wave starts, and before leaving it ends.
    private static let waveAfter: Double = 1.1
    private static let waveBefore: Double = 1.5
    /// A moment mid-wave, for a still picture.
    static var stillMoment: Double { descent + stay / 2 }

    /// Whether the elves are about, by the viewer's own clock.
    static func isSeason(on date: Date, calendar: Calendar = .current) -> Bool {
        SeasonalCalendar.elves.contains(date, calendar: calendar)
    }

    static func plan(isFirst: Bool, using random: inout some RandomNumberGenerator) -> Plan {
        Plan(
            wait: .random(in: isFirst ? firstWait : wait, using: &random),
            onLeading: .random(using: &random),
            lane: .random(in: 0...1, using: &random),
            depth: .random(in: 0.55...1, using: &random)
        )
    }

    /// Nil before the visit and once the elf is back out of sight.
    static func pose(at elapsed: TimeInterval) -> Pose? {
        guard elapsed >= 0, elapsed < duration else { return nil }
        let reach: Double
        var effort: Double = 0
        if elapsed < descent {
            // A slide that slows, and a little bounce as the rope takes it.
            let share = elapsed / descent
            reach = 1 - pow(1 - share, 3) + 0.05 * sin(share * .pi) * share
            effort = 1 - share
        } else if elapsed < descent + stay {
            reach = 1
        } else {
            reach = 1 - hauled((elapsed - descent - stay) / climb)
            effort = 1
        }
        let waving = elapsed - descent - waveAfter
        let raise = max(0, min(1, waving / 0.35, (descent + stay - waveBefore - elapsed) / 0.35))
        return Pose(
            reach: reach,
            sway: (0.03 + 0.07 * min(1, reach)) * sin(elapsed * 2 * .pi / 2.7),
            raise: smooth(raise),
            wave: sin(waving * 2 * .pi * 1.8),
            kick: (0.2 + 0.8 * effort) * sin(elapsed * 2 * .pi * 1.4)
        )
    }

    /// The way up, 0 to 1: a pull, a pause, a pull.
    static func hauled(_ share: Double) -> Double {
        let pull = max(0, min(1, share)) * Double(pulls)
        let done = pull.rounded(.down)
        return min(1, (done + smooth(min(1, (pull - done) / 0.62))) / Double(pulls))
    }

    private static func smooth(_ share: Double) -> Double { share * share * (3 - 2 * share) }
}

/// The elf's shapes, about the place its upper hand grips the rope, in units
/// where it is 100 tall from that hand to its heels. Its waving arm is on
/// the trailing side.
nonisolated enum ElfGeometry {
    /// From the grip to the rope's loose end.
    static let ropeTail: Double = 126
    /// The whole figure's reach above and below the grip, for hiding it.
    static let top: Double = -8
    static let bottom: Double = 132
    /// Half its width, the waving arm included.
    static let halfWidth: Double = 40

    static let upperHand = CGPoint(x: 1.5, y: 0)
    static let lowerHand = CGPoint(x: -1.5, y: 10)
    static let handRadius: Double = 4.2
    static let leftShoulder = CGPoint(x: -10, y: 59)
    static let rightShoulder = CGPoint(x: 10, y: 59)
    static let armLine: Double = 7

    /// The arm that stays on the rope.
    static let holdingArm: Path = {
        var path = Path()
        path.move(to: leftShoulder)
        path.addQuadCurve(to: lowerHand, control: CGPoint(x: -24, y: 36))
        return path
    }()

    /// Where the other hand is: on the rope, or out to the side and waving.
    static func freeHand(raise: Double, wave: Double) -> CGPoint {
        let out = CGPoint(x: 30 + 4.5 * wave, y: 30 - 3 * abs(wave))
        return CGPoint(
            x: upperHand.x + (out.x - upperHand.x) * raise,
            y: upperHand.y + (out.y - upperHand.y) * raise
        )
    }

    static func freeArm(raise: Double, wave: Double) -> Path {
        let hand = freeHand(raise: raise, wave: wave)
        var path = Path()
        path.move(to: rightShoulder)
        path.addQuadCurve(to: hand, control: CGPoint(x: 24 + 4 * raise, y: 36 + 16 * raise))
        return path
    }

    static let head = Path(ellipseIn: CGRect(x: -13, y: 31, width: 26, height: 26))

    /// Two pointed ears.
    static let ears: Path = {
        var path = Path()
        for side in [-1.0, 1.0] {
            path.move(to: CGPoint(x: side * 11, y: 39))
            path.addQuadCurve(to: CGPoint(x: side * 25, y: 33), control: CGPoint(x: side * 18, y: 39))
            path.addQuadCurve(to: CGPoint(x: side * 11.5, y: 50), control: CGPoint(x: side * 19, y: 46))
            path.closeSubpath()
        }
        return path
    }()

    static let eyes: Path = {
        var path = Path()
        path.addEllipse(in: CGRect(x: -6.4, y: 41.6, width: 3.4, height: 3.8))
        path.addEllipse(in: CGRect(x: 3, y: 41.6, width: 3.4, height: 3.8))
        return path
    }()

    static let cheeks: Path = {
        var path = Path()
        path.addEllipse(in: CGRect(x: -11.2, y: 46, width: 5.6, height: 4.4))
        path.addEllipse(in: CGRect(x: 5.6, y: 46, width: 5.6, height: 4.4))
        return path
    }()

    /// Stroked.
    static let smile: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -4, y: 49.5))
        path.addQuadCurve(to: CGPoint(x: 4, y: 49.5), control: CGPoint(x: 0, y: 54))
        return path
    }()

    /// The cap: a cone that flops over to the trailing side.
    static let cap: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -13.5, y: 36))
        path.addCurve(to: CGPoint(x: 6, y: 14), control1: CGPoint(x: -13, y: 25), control2: CGPoint(x: -5, y: 15))
        path.addCurve(to: CGPoint(x: 25, y: 29), control1: CGPoint(x: 16, y: 13), control2: CGPoint(x: 24, y: 20))
        path.addCurve(to: CGPoint(x: 13.5, y: 36), control1: CGPoint(x: 20, y: 24), control2: CGPoint(x: 14, y: 27))
        path.closeSubpath()
        return path
    }()

    /// The cap's band, stroked, and its bobble.
    static let band: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -13, y: 36))
        path.addQuadCurve(to: CGPoint(x: 13, y: 36), control: CGPoint(x: 0, y: 32.5))
        return path
    }()

    static let bandLine: Double = 6
    static let bobble = Path(ellipseIn: CGRect(x: 20.5, y: 26.5, width: 9.5, height: 9.5))

    /// The tunic, with a pointed hem.
    static let tunic: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -10.5, y: 57))
        path.addLine(to: CGPoint(x: 10.5, y: 57))
        path.addQuadCurve(to: CGPoint(x: 16, y: 86), control: CGPoint(x: 15, y: 70))
        let hem: [(x: Double, y: Double)] = [(12, 92), (8, 86), (4, 92), (0, 86), (-4, 92), (-8, 86), (-12, 92)]
        for point in hem {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        path.addLine(to: CGPoint(x: -16, y: 86))
        path.addQuadCurve(to: CGPoint(x: -10.5, y: 57), control: CGPoint(x: -15, y: 70))
        path.closeSubpath()
        return path
    }()

    /// The collar's points, over the tunic's top.
    static let collar: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -11.5, y: 56))
        let points: [(x: Double, y: Double)] = [(-8, 64), (-4, 58), (0, 65), (4, 58), (8, 64), (11.5, 56)]
        for point in points {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        path.closeSubpath()
        return path
    }()

    /// Stroked.
    static let belt: Path = {
        var path = Path()
        path.move(to: CGPoint(x: -14, y: 76))
        path.addQuadCurve(to: CGPoint(x: 14, y: 76), control: CGPoint(x: 0, y: 78.5))
        return path
    }()

    static let beltLine: Double = 5
    static let buckle = CGRect(x: -3.6, y: 73.6, width: 7.2, height: 6.6)

    struct Leg: Equatable {
        let hip: CGPoint
        let knee: CGPoint
        let ankle: CGPoint
        /// The shoe's curled toe.
        let toe: CGPoint
    }

    static let legLine: Double = 6.4

    /// The legs, swinging against each other. Trailing leg last.
    static func legs(kick: Double) -> [Leg] {
        [-1.0, 1.0].map { side in
            let swing = kick * side
            let knee = CGPoint(x: side * 9 + 3.5 * swing, y: 100)
            let ankle = CGPoint(x: side * 7.5 + 7 * swing, y: 112)
            return Leg(
                hip: CGPoint(x: side * 6, y: 87),
                knee: knee,
                ankle: ankle,
                toe: CGPoint(x: ankle.x + side * 9, y: ankle.y - 1.5)
            )
        }
    }

    /// A shoe: a pointed slipper whose toe curls up, pointing away from the rope.
    static func shoe(of leg: Leg, side: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: leg.ankle.x - side * 3.5, y: leg.ankle.y - 2))
        path.addQuadCurve(
            to: CGPoint(x: leg.toe.x + side * 2, y: leg.toe.y - 5),
            control: CGPoint(x: leg.toe.x + side * 2, y: leg.ankle.y + 1)
        )
        path.addQuadCurve(
            to: CGPoint(x: leg.ankle.x - side * 3.5, y: leg.ankle.y + 5),
            control: CGPoint(x: leg.toe.x - side * 1, y: leg.ankle.y + 7.5)
        )
        path.closeSubpath()
        return path
    }
}
