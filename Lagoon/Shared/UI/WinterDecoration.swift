import SwiftUI

/// A snowy page's backdrop decoration: frost in the top corners and light
/// snow falling behind the content. The snow stops under Reduce Motion and
/// while the player is up.
struct WinterDecoration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerCover) private var playerCover

    var body: some View {
        let ice = Theme.palette.snow
        ZStack(alignment: .top) {
            FrostCorners(color: ice)
            TimelineView(.animation(minimumInterval: Motion.snowFrame, paused: isStill)) { timeline in
                SnowfallFrame(time: timeline.date.timeIntervalSinceReferenceDate, color: ice)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isStill: Bool {
        reduceMotion || playerCover?.isPlayerUp == true
    }
}

/// Frost in both top corners: a haze, ice crystals and specks, all fading
/// away from the corner. Drawn once.
struct FrostCorners: View {
    let color: Color

    private static let left = FrostGeometry.frost(size: Metrics.frostSize, seed: 3)
    private static let right = FrostGeometry.frost(size: Metrics.frostSize, seed: 11)
    /// The haze reaches a little past the last crystal.
    private static let haze = Metrics.frostSize * 1.4

    var body: some View {
        Canvas { context, size in
            Self.draw(Self.left, in: &context, color: color)
            var mirrored = context
            mirrored.translateBy(x: size.width, y: 0)
            mirrored.scaleBy(x: -1, y: 1)
            Self.draw(Self.right, in: &mirrored, color: color)
        }
        .frame(height: Self.haze)
    }

    private static func draw(_ frost: FrostGeometry.Frost, in context: inout GraphicsContext, color: Color) {
        let size = Metrics.frostSize
        context.fill(
            Path(CGRect(x: 0, y: 0, width: haze, height: haze)),
            with: .radialGradient(
                Gradient(colors: [color.opacity(0.2), color.opacity(0.07), color.opacity(0)]),
                center: .zero, startRadius: 0, endRadius: haze
            )
        )
        for crystal in frost.crystals {
            var turned = context
            turned.translateBy(x: crystal.center.x, y: crystal.center.y)
            turned.rotate(by: .radians(crystal.turn))
            turned.stroke(
                SnowflakeGeometry.frostPath(radius: crystal.radius),
                with: .color(color.opacity(0.08 + 0.5 * FrostGeometry.strength(at: crystal.center, size: size))),
                // A big crystal is drawn a little heavier than a small one.
                style: StrokeStyle(
                    lineWidth: Metrics.frostLineWidth * (0.6 + crystal.radius / size),
                    lineCap: .round, lineJoin: .round
                )
            )
        }
        for speck in frost.specks {
            let radius = Metrics.frostLineWidth * 0.9 * speck.radius
            context.fill(
                Path(ellipseIn: CGRect(
                    x: speck.center.x - radius, y: speck.center.y - radius, width: radius * 2, height: radius * 2
                )),
                with: .color(color.opacity(0.55 * FrostGeometry.strength(at: speck.center, size: size)))
            )
        }
    }
}

/// The snow at one moment.
struct SnowfallFrame: View {
    let time: TimeInterval
    let color: Color

    private static let flakes = Snowfall.flakes(count: Metrics.snowflakeCount, seed: 5)
    /// One crystal of radius 1, scaled to each flake.
    private static let crystal = SnowflakeGeometry.path(radius: 1)
    /// A soft flake fades out over this many times its radius.
    private static let softness = 1.9

    var body: some View {
        Canvas { context, size in
            for flake in Self.flakes {
                let pose = Snowfall.pose(
                    of: flake, at: time, in: size,
                    dot: Metrics.snowflakeRadius, crystal: Metrics.snowCrystalRadius
                )
                if pose.isCrystal {
                    var turned = context
                    turned.translateBy(x: pose.center.x, y: pose.center.y)
                    turned.rotate(by: .radians(pose.turn))
                    turned.scaleBy(x: pose.radius, y: pose.radius)
                    turned.stroke(
                        Self.crystal, with: .color(color.opacity(pose.opacity)),
                        style: StrokeStyle(lineWidth: 0.13, lineCap: .round, lineJoin: .round)
                    )
                } else {
                    let reach = pose.radius * Self.softness
                    let ink = color.opacity(pose.opacity)
                    context.fill(
                        Path(ellipseIn: CGRect(
                            x: pose.center.x - reach, y: pose.center.y - reach, width: reach * 2, height: reach * 2
                        )),
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: ink, location: 0),
                                .init(color: ink.opacity(0.55), location: 0.45),
                                .init(color: ink.opacity(0), location: 1),
                            ]),
                            center: pose.center, startRadius: 0, endRadius: reach
                        )
                    )
                }
            }
        }
    }
}
