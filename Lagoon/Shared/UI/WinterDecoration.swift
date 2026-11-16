import SwiftUI

/// A snowy page's backdrop decoration: light snow falling behind the
/// content. Nothing moves under Reduce Motion or while the player is up.
struct WinterDecoration: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.playerCover) private var playerCover

    private static let flakes = Snowfall.flakes(count: Metrics.snowflakeCount, seed: 5)

    var body: some View {
        let color = Theme.palette.snow
        TimelineView(.animation(minimumInterval: Motion.snowFrame, paused: isStill)) { timeline in
            SnowfallFrame(flakes: Self.flakes, time: timeline.date.timeIntervalSinceReferenceDate, color: color)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isStill: Bool {
        reduceMotion || playerCover?.isPlayerUp == true
    }
}

/// The snow at one moment.
struct SnowfallFrame: View {
    let flakes: [Snowfall.Flake]
    let time: TimeInterval
    let color: Color

    var body: some View {
        Canvas { context, size in
            for flake in flakes {
                let pose = Snowfall.pose(of: flake, at: time, in: size, radius: Metrics.snowflakeRadius)
                let box = CGRect(
                    x: pose.center.x - pose.radius, y: pose.center.y - pose.radius,
                    width: pose.radius * 2, height: pose.radius * 2
                )
                context.fill(Path(ellipseIn: box), with: .color(color.opacity(pose.opacity)))
            }
        }
    }
}
