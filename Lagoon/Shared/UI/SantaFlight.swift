import SwiftUI

/// The Christmas surprise: Santa's sleigh and three pairs of reindeer cross
/// the sky over the pages, leaving gold dust that twinkles and falls. Where
/// everything is depends only on the time since the flight began, so any
/// moment can be drawn.
nonisolated enum SantaFlight {
    /// Seconds the sleigh takes from one edge of the page to the other.
    static let crossing: Double = 9.5
    /// Seconds a mote of dust stays alight.
    static let dustLife: ClosedRange<Double> = 1.5...3.2
    /// The whole show, the last of the dust included.
    static var duration: Double { crossing + dustLife.upperBound }
    /// Seconds a page is on screen before the sleigh sets out.
    static let wait: Double = 2.5
    /// The moment Reduce Motion shows, and for how long.
    static let stillMoment: Double = 5.2
    static let stillDuration: Double = 4

    // The figures are drawn in their own units: a reindeer's body is 100 long.

    /// From the sleigh's back to the lead reindeer's nose.
    static let teamLength: Double = 700
    /// How far ahead of the sleigh each pair runs, the lead last.
    static let pairs: [Double] = [188, 343, 498]
    /// The far reindeer of a pair runs a little ahead of and above the near one.
    static let farOffset = CGPoint(x: 26, y: -14)
    /// Where the dust leaves the sleigh, behind its middle.
    static let wake: Double = -76
    /// Strides a second.
    static let gallop: Double = 1.7

    /// Points to a unit. The team spans this share of the page's width,
    /// within limits, so it is neither lost on a television nor cramped on a
    /// phone.
    static func scale(in size: CGSize) -> Double {
        min(max(size.width * 0.46, 280), 900) / teamLength
    }

    /// The sleigh's middle across the page. It starts with the lead's nose
    /// off the leading edge and ends with its own back off the trailing one.
    static func sleighX(at time: Double, in size: CGSize) -> Double {
        let unit = scale(in: size)
        let start = -((pairs.last ?? 0) + farOffset.x + 100) * unit
        let end = size.width + 120 * unit
        return start + (end - start) * time / crossing
    }

    /// The flight's height at a place across the page: an arc that climbs
    /// from the leading edge and is highest past the middle. A tall page
    /// keeps the climb its width allows, or the team would stand on end.
    static func height(at x: Double, in size: CGSize) -> Double {
        let across = x / size.width
        let climb = min(size.height * 0.17, size.width * 0.2)
        return size.height * 0.23 + climb * (1 - sin(.pi * (0.08 + 0.78 * across)))
    }

    /// Where a figure is and how it leans.
    struct Placement: Equatable {
        let center: CGPoint
        /// Radians, following the arc.
        let turn: Double
    }

    /// A figure `ahead` units in front of the sleigh's middle. `bob` is how
    /// far it rises and falls with its stride, in units.
    static func placement(
        ahead: Double, lift: Double = 0, bob: Double = 0, phase: Double = 0, at time: Double, in size: CGSize
    ) -> Placement {
        let unit = scale(in: size)
        let x = sleighX(at: time, in: size) + ahead * unit
        let slope = (height(at: x + 1, in: size) - height(at: x - 1, in: size)) / 2
        let rise = lift + bob * sin(time * 2 * .pi * gallop + phase)
        return Placement(
            center: CGPoint(x: x, y: height(at: x, in: size) + rise * unit),
            turn: atan(slope)
        )
    }

    /// One of the team: the sleigh or a reindeer.
    struct Member: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case sleigh
            /// The reindeer of a pair nearer the viewer, and the one beyond it.
            case near
            case far
        }

        let kind: Kind
        /// Units ahead of the sleigh's middle, and above the flight's line.
        let ahead: Double
        let lift: Double
        /// How far it rises and falls with its stride, in units.
        let bob: Double
        /// Where it is in its stride, so no two run in step.
        let phase: Double
        /// The reindeer with the red nose.
        let isLead: Bool
    }

    /// The team in the order it is drawn: each pair's far reindeer, then its
    /// near one, from the sleigh outward, and the sleigh over them all.
    static let team: [Member] = pairs.enumerated().flatMap { index, ahead in
        let phase = Double(index) * 1.9
        return [
            Member(
                kind: .far, ahead: ahead + farOffset.x, lift: farOffset.y, bob: 3, phase: phase + 1.1, isLead: false
            ),
            Member(kind: .near, ahead: ahead, lift: 0, bob: 3, phase: phase, isLead: index == pairs.count - 1),
        ]
    } + [Member(kind: .sleigh, ahead: 0, lift: 0, bob: 1.4, phase: 2.2, isLead: false)]

    static func placement(of member: Member, at time: Double, in size: CGSize) -> Placement {
        placement(ahead: member.ahead, lift: member.lift, bob: member.bob, phase: member.phase, at: time, in: size)
    }

    /// How much the page dims while the sleigh is over it: enough that the
    /// gold reads over bright artwork, and the page stays a page.
    static let scrim = 0.42
    /// Seconds the page takes to dim as the sleigh arrives, and to clear.
    static let dimIn: Double = 1
    static let dimOut: Double = 1.6

    /// A reindeer's legs: 0 stretched out, 1 gathered under it.
    static func stride(at time: Double, phase: Double) -> Double {
        0.5 - 0.5 * cos(time * 2 * .pi * gallop + phase)
    }

    /// How much of the show is on the page, for the dimming behind it: it
    /// arrives over a second and leaves with the last of the dust.
    static func presence(at time: Double) -> Double {
        max(0, min(1, time / dimIn, (duration - time) / dimOut))
    }

    // MARK: - Dust

    struct Mote: Equatable, Sendable {
        /// Seconds into the flight when it leaves the sleigh.
        let born: Double
        /// From the wake, in units.
        let offset: CGPoint
        /// Units a second, downward and back along the flight.
        let fall: Double
        let drift: Double
        /// Seconds alight.
        let life: Double
        /// Units.
        let size: Double
        let isStar: Bool
        let twinkle: Double
        let phase: Double
        /// Which of the dust's colours it burns in.
        let tint: Int
    }

    /// A mote at one moment.
    struct Spark: Equatable {
        let center: CGPoint
        let radius: Double
        let opacity: Double
        let turn: Double
        let isStar: Bool
        let tint: Int
    }

    static let dust = motes(count: 230, seed: 1224)

    /// Motes leaving the sleigh evenly for as long as it is over the page.
    static func motes(count: Int, seed: UInt64) -> [Mote] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { index in
            let isStar = Double.random(in: 0...1, using: &generator) < 0.55
            return Mote(
                born: (Double(index) + Double.random(in: 0...1, using: &generator)) / Double(count) * crossing,
                offset: CGPoint(
                    x: Double.random(in: -10...10, using: &generator),
                    y: Double.random(in: -16...22, using: &generator)
                ),
                fall: Double.random(in: 8...34, using: &generator),
                drift: Double.random(in: -6...22, using: &generator),
                life: Double.random(in: dustLife, using: &generator),
                size: isStar
                    ? Double.random(in: 5...13, using: &generator)
                    : Double.random(in: 1.8...4, using: &generator),
                isStar: isStar,
                twinkle: Double.random(in: 5...11, using: &generator),
                phase: Double.random(in: 0...(2 * .pi), using: &generator),
                tint: Int.random(in: 0..<3, using: &generator)
            )
        }
    }

    /// The dust still alight at a moment.
    static func sparks(at time: Double, in size: CGSize) -> [Spark] {
        dust.compactMap { spark(of: $0, aged: time - $0.born, in: size) }
    }

    /// A mote so long after it left the sleigh. Nil before that and once it
    /// has burnt out.
    static func spark(of mote: Mote, aged age: Double, in size: CGSize) -> Spark? {
        guard age > 0, age < mote.life else { return nil }
        let unit = scale(in: size)
        let birth = placement(ahead: wake, at: mote.born, in: size).center
        let spent = age / mote.life
        let glitter = 0.5 + 0.5 * sin(age * mote.twinkle + mote.phase)
        return Spark(
            center: CGPoint(
                x: birth.x + (mote.offset.x - mote.drift * age) * unit,
                y: birth.y + (mote.offset.y + mote.fall * age + 9 * age * age) * unit
            ),
            radius: mote.size * unit * (1 - moteShrink * spent),
            opacity: min(1, age / 0.12) * pow(1 - spent, 1.3) * (0.35 + 0.65 * glitter),
            turn: mote.phase + age * moteSpin,
            isStar: mote.isStar,
            tint: mote.tint
        )
    }

    /// How much smaller a mote is by the time it burns out, and how fast a
    /// star turns, in radians a second.
    static let moteShrink = 0.35
    static let moteSpin = 0.9

    // MARK: - Reins

    static let reinsLine: Double = 1.5
    static let reinsOpacity = 0.8

    /// A figure's own point, on the page.
    static func point(_ own: CGPoint, on placement: Placement, unit: Double) -> CGPoint {
        let turned = CGPoint(
            x: own.x * cos(placement.turn) - own.y * sin(placement.turn),
            y: own.x * sin(placement.turn) + own.y * cos(placement.turn)
        )
        return CGPoint(x: placement.center.x + turned.x * unit, y: placement.center.y + turned.y * unit)
    }

    /// The corners of the reins: the driver's hand, then each near
    /// reindeer's collar, the lead's last.
    static func reinPoints(at time: Double, in size: CGSize) -> [CGPoint] {
        let unit = scale(in: size)
        return team.filter { $0.kind == .sleigh }.map {
            point(SantaGeometry.hand, on: placement(of: $0, at: time, in: size), unit: unit)
        } + team.filter { $0.kind == .near }.map {
            point(SantaGeometry.collar, on: placement(of: $0, at: time, in: size), unit: unit)
        }
    }

    static func reins(at time: Double, in size: CGSize) -> Path {
        var path = Path()
        path.addLines(reinPoints(at: time, in: size))
        return path
    }

}

/// When the Christmas surprise is due, by the viewer's own clock.
nonisolated enum Christmas {
    /// A stamp for each day the sleigh flies, every one its own, and nothing
    /// on any other day.
    static func day(on date: Date, calendar: Calendar = .current) -> Int? {
        guard SeasonalCalendar.santa.contains(date, calendar: calendar) else { return nil }
        let parts = SeasonalCalendar.gregorian(on: calendar).dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return year * 10_000 + month * 100 + day
    }
}
