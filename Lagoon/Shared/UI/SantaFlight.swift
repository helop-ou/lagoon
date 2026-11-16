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

    /// A reindeer's legs: 0 stretched out, 1 gathered under it.
    static func stride(at time: Double, phase: Double) -> Double {
        0.5 - 0.5 * cos(time * 2 * .pi * gallop + phase)
    }

    /// How much of the show is on the page, for the dimming behind it: it
    /// arrives over a second and leaves with the last of the dust.
    static func presence(at time: Double) -> Double {
        max(0, min(1, time / 1.0, (duration - time) / 1.6))
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
        let unit = scale(in: size)
        return dust.compactMap { mote in
            let age = time - mote.born
            guard age > 0, age < mote.life else { return nil }
            let birth = placement(ahead: wake, at: mote.born, in: size).center
            let spent = age / mote.life
            let glitter = 0.5 + 0.5 * sin(age * mote.twinkle + mote.phase)
            return Spark(
                center: CGPoint(
                    x: birth.x + (mote.offset.x - mote.drift * age) * unit,
                    y: birth.y + (mote.offset.y + mote.fall * age + 9 * age * age) * unit
                ),
                radius: mote.size * unit * (1 - 0.35 * spent),
                opacity: min(1, age / 0.12) * pow(1 - spent, 1.3) * (0.35 + 0.65 * glitter),
                turn: mote.phase + age * 0.9,
                isStar: mote.isStar,
                tint: mote.tint
            )
        }
    }

    /// The bright wake straight behind the sleigh: where it was over the
    /// last moments, newest first.
    static func ribbon(at time: Double, in size: CGSize, points: Int = 16) -> [CGPoint] {
        (0..<points).compactMap { index in
            let past = time - Double(index) * 0.045
            guard past > 0 else { return nil }
            return placement(ahead: wake + 6, lift: 18, at: past, in: size).center
        }
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
