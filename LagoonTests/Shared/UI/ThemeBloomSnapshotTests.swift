import SwiftUI
import Testing
@testable import Lagoon

/// Each theme's bloom halfway through, over its own background: the motif,
/// its colour and which way it drifts.
@Suite("Theme bloom snapshots", .serialized)
@MainActor
struct ThemeBloomSnapshotTests {
    @Test(arguments: AppTheme.allCases)
    func aThemesMotifDriftsThroughItsBloom(theme: AppTheme) async throws {
        let bloom = ThemeBloomFrame(
            accent: theme.palette.accent,
            motif: theme.bloomMotif,
            progress: 0.5,
            seed: 3,
            reduceMotion: false
        )
        .background(theme.palette.background)

        try await Snapshot.verify(bloom, named: "bloom-\(theme.rawValue)", size: CGSize(width: 600, height: 400))
    }
}
