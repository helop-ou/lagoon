import SwiftUI

/// The winter theme's snowflake: six arms about the origin, each with pairs
/// of side branches. Stroked, never filled.
nonisolated enum SnowflakeGeometry {
    static let arms = 6

    /// Where an arm's side branches leave it, and how long each is, both as a
    /// share of the radius. A falling flake has two pairs. A frost crystal is
    /// seen larger, so it has four and a hexagon at its heart.
    private static let flakeBranches: [(along: Double, length: Double)] = [(0.45, 0.3), (0.72, 0.2)]
    private static let frostBranches: [(along: Double, length: Double)] = [
        (0.3, 0.18), (0.5, 0.3), (0.7, 0.22), (0.86, 0.12),
    ]
    private static let frostHeart = 0.14

    static func path(radius: Double) -> Path {
        crystal(radius: radius, branches: flakeBranches, heart: 0)
    }

    static func frostPath(radius: Double) -> Path {
        crystal(radius: radius, branches: frostBranches, heart: frostHeart)
    }

    static func strokeStyle(radius: Double) -> StrokeStyle {
        StrokeStyle(lineWidth: max(1, radius * 0.12), lineCap: .round, lineJoin: .round)
    }

    private static func crystal(radius: Double, branches: [(along: Double, length: Double)], heart: Double) -> Path {
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
        guard heart > 0 else { return path }
        var hexagon = Path()
        for index in 0..<arms {
            let angle = Double(index) / Double(arms) * 2 * .pi
            let corner = CGPoint(x: sin(angle) * radius * heart, y: -cos(angle) * radius * heart)
            if index == 0 { hexagon.move(to: corner) } else { hexagon.addLine(to: corner) }
        }
        hexagon.closeSubpath()
        path.addPath(hexagon)
        return path
    }
}

/// The winter theme's falling snow: a fixed set of flakes, each on its own
/// lane, falling from above the page to below it and starting again. A near
/// flake is a crystal that turns as it falls, a far one a soft dot. Where a
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
        /// Radians, so the flakes do not sway or turn together.
        let phase: Double
    }

    struct Pose: Equatable {
        let center: CGPoint
        let radius: Double
        let opacity: Double
        /// Near enough to be seen as a crystal, and how far it has turned.
        let isCrystal: Bool
        let turn: Double
    }

    /// Seconds from the top of the page to the bottom, near to far.
    static let fall: ClosedRange<Double> = 14...30
    /// Seconds for one sway from side to side and back.
    static let swayPeriod: Double = 7
    static let opacity: ClosedRange<Double> = 0.25...0.85
    /// From this depth on a flake is close enough to show its arms.
    static let crystalDepth = 0.55
    /// Radians a crystal turns in a second.
    static let spin = 0.3

    static func flakes(count: Int, seed: UInt64) -> [Flake] {
        var generator = SeededGenerator(seed: seed)
        return (0..<count).map { _ in
            Flake(
                lane: Double.random(in: 0...1, using: &generator),
                start: Double.random(in: 0...1, using: &generator),
                // Raised, so most of the snow is far off and fewer flakes are close.
                depth: pow(Double.random(in: 0...1, using: &generator), 1.6),
                phase: Double.random(in: 0...(2 * .pi), using: &generator)
            )
        }
    }

    /// Seconds a flake takes from the top of the page to the bottom.
    static func seconds(of flake: Flake) -> Double {
        fall.upperBound - (fall.upperBound - fall.lowerBound) * flake.depth
    }

    /// How far through its fall a flake is, 0 to 1.
    static func progress(of flake: Flake, at time: TimeInterval) -> Double {
        (flake.start + time / seconds(of: flake)).truncatingRemainder(dividingBy: 1)
    }

    /// How far a flake swings to either side of its lane, in its own radii.
    /// A crystal is wide already. A dot swings further for its size.
    static func swing(isCrystal: Bool) -> Double { isCrystal ? 1.5 : 3 }

    /// `dot` is the farthest soft flake's radius and the nearest's, `crystal`
    /// the same for the flakes close enough to be crystals. A flake enters
    /// and leaves wholly off the page.
    static func pose(
        of flake: Flake, at time: TimeInterval, in page: CGSize,
        dot: ClosedRange<Double>, crystal: ClosedRange<Double>
    ) -> Pose {
        let isCrystal = flake.depth >= crystalDepth
        let size = if isCrystal {
            crystal.lowerBound + (crystal.upperBound - crystal.lowerBound) * (flake.depth - crystalDepth) / (1 - crystalDepth)
        } else {
            dot.lowerBound + (dot.upperBound - dot.lowerBound) * flake.depth / crystalDepth
        }
        let progress = progress(of: flake, at: time)
        let sway = sin(time / swayPeriod * 2 * .pi + flake.phase) * size * swing(isCrystal: isCrystal)
        return Pose(
            center: CGPoint(
                x: flake.lane * page.width + sway,
                y: -size + progress * (page.height + 2 * size)
            ),
            radius: size,
            opacity: opacity.lowerBound + (opacity.upperBound - opacity.lowerBound) * flake.depth,
            isCrystal: isCrystal,
            turn: flake.phase + time * spin
        )
    }
}

/// Frost in the top-left corner of a page: ice crystals grown along both
/// edges out of the corner, the biggest at the corner and smaller ones
/// further along, with specks of ice between them. `seed` makes each corner
/// its own.
nonisolated enum FrostGeometry {
    struct Crystal: Equatable, Sendable {
        let center: CGPoint
        let radius: Double
        /// Radians.
        let turn: Double
    }

    struct Frost: Equatable, Sendable {
        let crystals: [Crystal]
        /// Where each speck is, and its size as a share of the biggest.
        let specks: [Crystal]
    }

    static let speckCount = 70

    static func frost(size: Double, seed: UInt64) -> Frost {
        var generator = SeededGenerator(seed: seed)
        var crystals = [Crystal(
            center: CGPoint(x: size * 0.06, y: size * 0.04),
            radius: size * 0.62,
            turn: Double.random(in: 0...1, using: &generator)
        )]
        for alongTop in [true, false] {
            var along = size * 0.38
            var radius = size * 0.34
            while along < size * 1.05, radius > size * 0.07 {
                // Sitting on the edge, a little in or a little out.
                let inset = radius * Double.random(in: -0.25...0.2, using: &generator)
                crystals.append(Crystal(
                    center: alongTop ? CGPoint(x: along, y: inset) : CGPoint(x: inset, y: along),
                    radius: radius,
                    turn: Double.random(in: 0...1, using: &generator)
                ))
                along += radius * Double.random(in: 0.75...1.05, using: &generator)
                radius *= Double.random(in: 0.62...0.8, using: &generator)
            }
        }
        let specks = (0..<speckCount).map { _ in
            // Thick at the corner, thinning away from it.
            let distance = pow(Double.random(in: 0...1, using: &generator), 1.7) * size * reach
            let angle = Double.random(in: 0...(.pi / 2), using: &generator)
            return Crystal(
                center: CGPoint(x: cos(angle) * distance, y: sin(angle) * distance),
                radius: Double.random(in: 0.4...1, using: &generator),
                turn: 0
            )
        }
        return Frost(crystals: crystals, specks: specks)
    }

    /// How far the frost reaches from the corner, as a share of its size.
    static let reach = 1.2

    /// How strong the frost is at a point: 1 in the corner, 0 where it ends.
    static func strength(at point: CGPoint, size: Double) -> Double {
        max(0, 1 - hypot(point.x, point.y) / (size * reach))
    }
}
