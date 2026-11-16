import SwiftUI
import Testing
@testable import Lagoon

/// The New Year fireworks at one moment: the bursts in the theme's colours,
/// the scrim and the greeting.
@Suite("New Year snapshots", .serialized)
@MainActor
struct NewYearSnapshotTests {
    @Test func fireworksBurstOverTheBrandTheme() async throws {
        let show = FireworksFrame(time: 4.6, palette: AppTheme.lagoon.palette)
            .background(AppTheme.lagoon.palette.background)

        try await Snapshot.verify(show, named: "fireworks-lagoon", size: Self.size)
    }

    /// Reduce Motion's picture, which ignores the clock.
    @Test func theStillMomentShowsBurstsAndTheGreetingInWinter() async throws {
        let show = FireworksFrame(time: 0, palette: AppTheme.winter.palette, isStill: true)
            .background(AppTheme.winter.palette.background)

        try await Snapshot.verify(show, named: "fireworks-still-winter", size: Self.size)
    }

    private static var size: CGSize {
        // The whole screen, or the sparks draw twice as thick as they are.
        #if os(tvOS)
        CGSize(width: 1920, height: 1080)
        #else
        CGSize(width: 402, height: 600)
        #endif
    }
}
