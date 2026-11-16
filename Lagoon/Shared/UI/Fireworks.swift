import SwiftUI

/// The New Year fireworks: a fixed, seeded show of shells. Each climbs from
/// the bottom of the page, bursts into two rings of sparks and burns out as
/// they droop. Where everything is depends only on the time since the show
/// began, so any moment can be drawn.
nonisolated enum Fireworks {
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
        let sparks: Int
        /// Radians, so two bursts' sparks do not line up.
        let turn: Double
    }

    /// A streak of light: a rocket's tail or one spark.
    struct Streak: Equatable {
        let from: CGPoint
        let to: CGPoint
        let opacity: Double
    }

    /// Seconds from the ground to the burst, and from the burst to nothing.
    static let climb: Double = 0.9
    static let burn: Double = 1.9
    /// The whole show.
    static let duration: Double = 10
    /// How much of a second a streak trails behind its head.
    private static let trail: Double = 0.12
    /// A full moment of the show, drawn still under Reduce Motion, and how
    /// long that picture stays up.
    static let stillMoment: Double = 3.2
    static let stillDuration: Double = 5

    /// How present the show is, 0 to 1: it fades in as it starts and out as
    /// the last sparks die.
    static func presence(at time: Double) -> Double {
        max(0, min(1, time / 0.6, (duration - time) / 1.2))
    }

    /// The greeting arrives after the first burst and leaves before the end.
    static func greeting(at time: Double) -> Double {
        max(0, min(1, (time - 1.2) / 0.8, (duration - 0.5 - time) / 1.2))
    }

    /// Shells launched in turn through the show, the last early enough to
    /// burn out before it ends.
    static func show(shells: Int, tints: Int, seed: UInt64) -> [Shell] {
        var generator = SeededGenerator(seed: seed)
        let lastLaunch = duration - climb - burn - 0.4
        return (0..<shells).map { index in
            let slot = lastLaunch * Double(index) / Double(max(1, shells - 1))
            return Shell(
                launch: max(0, slot + Double.random(in: -0.25...0.25, using: &generator)),
                lane: Double.random(in: 0.14...0.86, using: &generator),
                apex: Double.random(in: 0.16...0.46, using: &generator),
                reach: Double.random(in: 0.22...0.38, using: &generator),
                tint: index % max(1, tints),
                sparks: 34,
                turn: Double.random(in: 0...(2 * .pi), using: &generator)
            )
        }
    }

    /// The rocket's tail while it climbs. Nil before launch and once it has
    /// burst.
    static func rocket(of shell: Shell, at time: Double, in page: CGSize) -> Streak? {
        let age = time - shell.launch
        guard age >= 0, age < climb else { return nil }
        func point(_ age: Double) -> CGPoint {
            let share = max(0, min(1, age / climb))
            let risen = 1 - pow(1 - share, 2)
            return CGPoint(x: shell.lane * page.width, y: page.height * (1 - risen * (1 - shell.apex)))
        }
        return Streak(from: point(age - trail), to: point(age), opacity: 0.6)
    }

    /// The burst's sparks. Empty before the burst and once it has burned
    /// out.
    static func sparks(of shell: Shell, at time: Double, in page: CGSize) -> [Streak] {
        let age = time - shell.launch - climb
        guard age >= 0, age < burn else { return [] }
        let center = CGPoint(x: shell.lane * page.width, y: shell.apex * page.height)
        let reach = shell.reach * min(page.width, page.height)
        func point(_ index: Int, _ age: Double) -> CGPoint {
            let share = max(0, age / burn)
            // Fast out of the burst, then slowing, and drooping all the while.
            let spread = (1 - exp(-3.2 * share)) / (1 - exp(-3.2))
            // Every other spark stops short, as an inner ring.
            let ring = index.isMultiple(of: 2) ? 1 : 0.58
            let angle = shell.turn + Double(index) / Double(shell.sparks) * 2 * .pi
            return CGPoint(
                x: center.x + cos(angle) * reach * spread * ring,
                y: center.y + sin(angle) * reach * spread * ring + reach * 0.3 * share * share
            )
        }
        let share = age / burn
        let opacity = 1 - share * share
        return (0..<shell.sparks).map { index in
            Streak(from: point(index, age - trail), to: point(index, age), opacity: opacity)
        }
    }
}
