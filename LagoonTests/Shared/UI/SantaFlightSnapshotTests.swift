import SwiftUI
import Testing
@testable import Lagoon

/// Santa's sleigh at one moment over a winter page: the team in gold, the
/// driver in red, the lead's red nose and the dust behind them.
@Suite("Santa's sleigh snapshots", .serialized)
@MainActor
struct SantaFlightSnapshotTests {
    @Test func theSleighCrossesAWinterPage() async throws {
        let flight = SantaFlightFrame(time: 5.2)
            .background(AppTheme.winter.palette.background)

        try await Snapshot.verify(flight, named: "santa-flight", size: Self.size, tolerance: Self.tolerance)
    }

    /// Reduce Motion's picture, which ignores the clock.
    @Test func theStillMomentShowsTheWholeTeam() async throws {
        let flight = SantaFlightFrame(time: 0, isStill: true)
            .background(AppTheme.lagoon.palette.background)

        try await Snapshot.verify(flight, named: "santa-flight-still", size: Self.size, tolerance: Self.tolerance)
    }

    /// The lead's nose is a sliver of the picture.
    private static let tolerance = 0.0005

    private static var size: CGSize {
        // The top of the screen at its real width, or the team is drawn too small.
        #if os(tvOS)
        CGSize(width: 1920, height: 620)
        #else
        CGSize(width: 402, height: 420)
        #endif
    }
}
