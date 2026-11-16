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
