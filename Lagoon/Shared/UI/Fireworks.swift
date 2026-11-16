import SwiftUI

/// The New Year fireworks: a fixed, seeded show of shells. Each climbs from
/// the bottom of the page and bursts with a flash into sparks that fly out,
/// trail, droop and glitter as they die. The show opens with one big shell,
/// builds, and ends in a volley. Where everything is depends only on the
/// time since the show began, so any moment can be drawn.
nonisolated enum Fireworks {
    /// How a shell bursts.
    enum Kind: Equatable, Sendable, CaseIterable {
        /// A full ball of sparks, flying at every speed.
        case peony
        /// A thin shell of sparks with long tails.
        case chrysanthemum
        /// Slow golden sparks that hang and fall a long way.
        case willow
        /// One clean ring around a small heart.
        case ring

        /// Seconds from the burst to nothing.
        var burn: Double { self == .willow ? 3 : 2.1 }
        /// How far the sparks fall by the end, as a share of the reach.
        var droop: Double { self == .willow ? 0.8 : 0.32 }
        /// How much of a second a spark's tail trails behind its head.
        var tail: Double {
            switch self {
            case .peony, .ring: 0.14
            case .chrysanthemum: 0.26
            case .willow: 0.42
            }
        }
    }

    struct Spark: Equatable, Sendable {
        /// Radians.
        let angle: Double
        /// How far it flies, as a share of the shell's reach.
        let speed: Double
        /// Where it is in its own glitter, 0 to 1, so sparks do not blink together.
        let flicker: Double
    }

    struct Shell: Equatable, Sendable {
        /// Seconds into the show when it leaves the ground.
        let launch: Double
        /// Across the page: 0 at the leading edge, 1 at the trailing.
        let lane: Double
        /// Where it bursts: 0 at the top of the page, 1 at the bottom.
        let apex: Double
        /// The burst's reach as a share of the page's shorter side.
        let reach: Double
        /// Which of the show's colours it burns in.
        let tint: Int
        let kind: Kind
        let sparks: [Spark]
    }

    /// A rocket's tail.
    struct Streak: Equatable {
        let from: CGPoint
        let to: CGPoint
        let opacity: Double
    }

    /// A burst at one moment: the sparks still alight, each as a line from
    /// its tail's end to its head.
    struct Burst: Equatable {
        let opacity: Double
        /// Tail first, head last, `tailPoints` points each.
        let trails: [[CGPoint]]
    }

    /// The flash as a shell bursts.
    struct Flash: Equatable {
        let center: CGPoint
        let radius: Double
        let opacity: Double
    }

    /// Seconds from the ground to the burst.
    static let climb: Double = 0.9
    /// The whole show: long enough for the volley's last willow to burn out.
    static let duration: Double = 13
    /// When the first shell of the closing volley bursts.
    static let finale: Double = 8.2
    /// How long a burst's flash lasts.
    static let flashTime: Double = 0.4
    /// From this share of its burn on, a spark glitters: it blinks as it dies.
    static let glitterFrom: Double = 0.55
    static let tailPoints = 4
    /// A full moment of the show, drawn still under Reduce Motion, and how
    /// long that picture stays up.
    static let stillMoment: Double = 9.3
    static let stillDuration: Double = 6

    /// How present the show is, 0 to 1: it fades in as it starts and out as
    /// the last sparks die.
    static func presence(at time: Double) -> Double {
        max(0, min(1, time / fadeIn, (duration - time) / fadeOut))
    }

    static let fadeIn: Double = 0.6
    static let fadeOut: Double = 1.4
    /// How dark the page goes under the show: enough that it does not fight it.
    static let scrim: Double = 0.7

    /// The opening shell, the shells that build, then the closing volley.
    static func show(tints: Int, seed: UInt64) -> [Shell] {
        var generator = SeededGenerator(seed: seed)
        let tints = max(1, tints)
        var shells = [shell(
            bursting: 1.4, lane: 0.5, apex: 0.3, reach: 0.44, tint: 2 % tints, kind: .chrysanthemum,
            using: &generator
        )]
        let building = 11
        for index in 0..<building {
            let kind = Kind.allCases[index % Kind.allCases.count]
            // Closer together as the show goes on.
            let share = Double(index) / Double(building - 1)
            shells.append(shell(
                bursting: 2.2 + 5.4 * pow(share, 0.8) + Double.random(in: -0.15...0.15, using: &generator),
                lane: Double.random(in: 0.12...0.88, using: &generator),
                apex: Double.random(in: 0.14...0.44, using: &generator),
                reach: Double.random(in: 0.24...0.36, using: &generator),
                tint: kind == .willow ? 2 % tints : index % tints,
                kind: kind,
                using: &generator
            ))
        }
        let volley = 9
        for index in 0..<volley {
            shells.append(shell(
                bursting: finale + 1.3 * Double(index) / Double(volley - 1),
                // Across the whole page, out of order.
                lane: 0.1 + 0.8 * Double((index * 4) % volley) / Double(volley - 1),
                // Bigger, and lower too, so the greeting stands among them.
                apex: Double.random(in: 0.14...0.6, using: &generator),
                reach: Double.random(in: 0.34...0.5, using: &generator),
                tint: index % tints,
                kind: Kind.allCases[(index + 1) % Kind.allCases.count],
                using: &generator
            ))
        }
        return shells
    }

    private static func shell(
        bursting: Double, lane: Double, apex: Double, reach: Double, tint: Int, kind: Kind,
        using generator: inout SeededGenerator
    ) -> Shell {
        Shell(
            launch: bursting - climb, lane: lane, apex: apex, reach: reach, tint: tint, kind: kind,
            sparks: sparks(of: kind, using: &generator)
        )
    }

    private static func sparks(of kind: Kind, using generator: inout SeededGenerator) -> [Spark] {
        func ring(_ count: Int, speed: ClosedRange<Double>, jitter: Double) -> [Spark] {
            let turn = Double.random(in: 0...(2 * .pi), using: &generator)
            return (0..<count).map { index in
                Spark(
                    angle: turn + (Double(index) + Double.random(in: -jitter...jitter, using: &generator))
                        / Double(count) * 2 * .pi,
                    speed: Double.random(in: speed, using: &generator),
                    flicker: Double.random(in: 0...1, using: &generator)
                )
            }
        }
        switch kind {
        case .peony:
            return (0..<84).map { _ in
                Spark(
                    angle: Double.random(in: 0...(2 * .pi), using: &generator),
                    // Raised, so the ball is fuller toward its edge.
                    speed: 0.25 + 0.75 * pow(Double.random(in: 0...1, using: &generator), 0.6),
                    flicker: Double.random(in: 0...1, using: &generator)
                )
            }
        case .chrysanthemum:
            return ring(64, speed: 0.86...1, jitter: 0.3) + ring(26, speed: 0.4...0.6, jitter: 0.4)
        case .willow:
            return ring(52, speed: 0.6...1, jitter: 0.4)
        case .ring:
            return ring(44, speed: 1...1, jitter: 0) + ring(22, speed: 0.3...0.45, jitter: 0.4)
        }
    }

    /// The rocket's tail while it climbs. Nil before launch and once it has
    /// burst.
    static func rocket(of shell: Shell, at time: Double, in page: CGSize) -> Streak? {
        let age = time - shell.launch
        guard age >= 0, age < climb else { return nil }
        return Streak(
            from: rocketPoint(of: shell, aged: age - rocketTail, in: page),
            to: rocketPoint(of: shell, aged: age, in: page), opacity: rocketOpacity
        )
    }

    /// How much of a second the rocket's tail trails behind it, and how
    /// bright it is.
    static let rocketTail: Double = 0.12
    static let rocketOpacity: Double = 0.7

    /// Where the rocket is so long after leaving the ground: fast at first,
    /// slowing to a stop where it bursts.
    static func rocketPoint(of shell: Shell, aged age: Double, in page: CGSize) -> CGPoint {
        let share = max(0, min(1, age / climb))
        let risen = 1 - pow(1 - share, 2)
        return CGPoint(x: shell.lane * page.width, y: page.height * (1 - risen * (1 - shell.apex)))
    }

    /// Where a spark is so long after its shell burst: fast out of the
    /// burst, then slowing, and falling all the while.
    static func point(of spark: Spark, in shell: Shell, aged age: Double, in page: CGSize) -> CGPoint {
        let reach = shell.reach * min(page.width, page.height)
        let share = max(0, age / shell.kind.burn)
        let spread = (1 - exp(-3.6 * share)) / (1 - exp(-3.6))
        return CGPoint(
            x: shell.lane * page.width + cos(spark.angle) * reach * spark.speed * spread,
            y: shell.apex * page.height + sin(spark.angle) * reach * spark.speed * spread
                + reach * shell.kind.droop * share * share
        )
    }

    /// How bright a burst is this far through its burn, 0 to 1.
    static func strength(burnt share: Double) -> Double {
        1 - pow(share, 3)
    }

    /// The flash as the shell bursts. Nil before the burst and once it has
    /// gone.
    static func flash(of shell: Shell, at time: Double, in page: CGSize) -> Flash? {
        let age = time - shell.launch - climb
        guard age >= 0, age < flashTime else { return nil }
        let share = age / flashTime
        return Flash(
            center: CGPoint(x: shell.lane * page.width, y: shell.apex * page.height),
            radius: shell.reach * min(page.width, page.height) * (0.3 + 0.8 * share),
            opacity: pow(1 - share, 2)
        )
    }

    /// The burst's sparks. Nil before the burst and once it has burned out.
    static func burst(of shell: Shell, at time: Double, in page: CGSize) -> Burst? {
        let burn = shell.kind.burn
        let age = time - shell.launch - climb
        guard age >= 0, age < burn else { return nil }
        let share = age / burn
        let alight = shell.sparks.filter { share < glitterFrom || isLit($0, at: time) }
        let tail = shell.kind.tail
        return Burst(
            opacity: strength(burnt: share),
            trails: alight.map { spark in
                (0..<tailPoints).map { index in
                    point(
                        of: spark, in: shell, aged: age - tail * (1 - Double(index) / Double(tailPoints - 1)),
                        in: page
                    )
                }
            }
        )
    }

    /// A glittering spark blinks about fourteen times a second, each on its
    /// own beat.
    static func isLit(_ spark: Spark, at time: Double) -> Bool {
        let beat = (time * 14 + spark.flicker * 7).rounded(.down)
        let noise = sin((beat + spark.flicker) * 12.9898) * 43758.5453
        return noise - noise.rounded(.down) > 0.45
    }
}
