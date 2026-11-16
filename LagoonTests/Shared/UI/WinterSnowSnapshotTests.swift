import SwiftUI
import Testing
@testable import Lagoon

/// A winter page's decoration at one moment, over its own background: frost
/// in the top corners, crystals close by and soft flakes far off. A flake is
/// a sliver of the picture, so one going missing is under any share worth
/// allowing: no pixel may change.
@Suite("Winter snow snapshots", .serialized)
@MainActor
struct WinterSnowSnapshotTests {
    @Test func frostAndSnowDecorateAWinterPage() async throws {
        let palette = AppTheme.winter.palette
        let page = ZStack(alignment: .top) {
            palette.background
            FrostCorners(color: palette.snow)
            SnowfallFrame(time: 100, color: palette.snow)
        }

        try await Snapshot.verify(page, named: "winter-snow", size: Self.size, tolerance: 0)
    }

    private static var size: CGSize {
        // Wide enough that the two corners' frost does not meet.
        #if os(tvOS)
        CGSize(width: 1920, height: 1080)
        #else
        CGSize(width: 402, height: 600)
        #endif
    }
}
