import SwiftUI

/// The winter theme's snowflake: six arms about the origin, each with two
/// pairs of side branches. Stroked, never filled.
nonisolated enum SnowflakeGeometry {
    static let arms = 6

    /// Where an arm's side branches leave it, and how long each is, both as a
    /// share of the radius.
    private static let branches: [(along: Double, length: Double)] = [(0.45, 0.3), (0.72, 0.2)]

    static func path(radius: Double) -> Path {
        var arm = Path()
        arm.move(to: .zero)
        arm.addLine(to: CGPoint(x: 0, y: -radius))
        for branch in branches {
            let root = CGPoint(x: 0, y: -radius * branch.along)
            let reach = radius * branch.length
            for side in [-1.0, 1.0] {
                arm.move(to: root)
                arm.addLine(to: CGPoint(x: side * reach * sin(.pi / 3), y: root.y - reach * cos(.pi / 3)))
            }
        }
        var path = Path()
        for index in 0..<arms {
            path.addPath(arm.applying(CGAffineTransform(rotationAngle: Double(index) / Double(arms) * 2 * .pi)))
        }
        return path
    }

    static func strokeStyle(radius: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: max(1, radius * 0.12), lineCap: .round, lineJoin: .round)
    }
}

/// The winter theme's falling snow: a fixed set of flakes, each on its own
/// lane, falling from above the page to below it and starting again. Where a
/// flake is depends only on the time, so any moment can be drawn.
nonisolated enum Snowfall {
    struct Flake: Equatable, Sendable {
        /// Across the page: 0 at the leading edge, 1 at the trailing.
        let lane: Double
        /// How far through its fall it is at time zero, 0 to 1.
        let start: Double
        /// 0 for the farthest flake and 1 for the nearest. A near flake is
        /// bigger, brighter and faster.
        let depth: Double
        /// Radians, so the flakes do not sway together.
        let phase: Double
    }

    struct Pose: Equatable {
        let center: CGPoint
        let radius: Double
        let opacity: Double
    }

    /// Seconds from the top of the page to the bottom, far to near.
    static let fall: ClosedRange<Double> = 14...30
    /// Seconds for one sway from side to side and back.
    static let swayPeriod: Double = 7
    static let opacity: ClosedRange<Double> = 0.22...0.7

    static func flakes(count: Int, seed: UInt64) -> [Flake] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            Flake(
                lane: Double.random(in: 0...1, using: &generator),
                start: Double.random(in: 0...1, using: &generator),
                // Squared, so most of the snow is far off and a few flakes are close.
                depth: pow(Double.random(in: 0...1, using: &generator), 2),
                phase: Double.random(in: 0...(2 * .pi), using: &generator)
            )
        }
    }

    /// `radius` is the farthest flake's and the nearest's. A flake enters and
    /// leaves wholly off the page.
    static func pose(of flake: Flake, at time: TimeInterval, in page: CGSize, radius: ClosedRange<Double>) -> Pose {
        let size = radius.lowerBound + (radius.upperBound - radius.lowerBound) * flake.depth
        let seconds = fall.upperBound - (fall.upperBound - fall.lowerBound) * flake.depth
        let progress = (flake.start + time / seconds).truncatingRemainder(dividingBy: 1)
        let sway = sin(time / swayPeriod * 2 * .pi + flake.phase) * size * 3
        return Pose(
            center: CGPoint(
                x: flake.lane * page.width + sway,
                y: -size + progress * (page.height + 2 * size)
            ),
            radius: size,
            opacity: opacity.lowerBound + (opacity.upperBound - opacity.lowerBound) * flake.depth
        )
    }
}
