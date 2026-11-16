import SwiftUI
import Testing
@testable import Lagoon

/// Winter's snow at one moment, over its own background. The flakes are a
/// sliver of the picture, so one missing flake is under any share worth
/// allowing: no pixel may change.
@Suite("Winter snow snapshots", .serialized)
@MainActor
struct WinterSnowSnapshotTests {
    @Test func snowFallsBehindAWinterPage() async throws {
        let palette = AppTheme.winter.palette
        let snow = SnowfallFrame(
            flakes: Snowfall.flakes(count: Metrics.snowflakeCount, seed: 5),
            time: 100,
            color: palette.snow
        )
        .background(palette.background)

        try await Snapshot.verify(snow, named: "winter-snow", size: Self.size, tolerance: 0)
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 960, height: 540)
        #else
        CGSize(width: 402, height: 500)
        #endif
    }
}
