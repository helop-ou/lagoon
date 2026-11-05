import SwiftUI
import Testing
@testable import Lagoon

/// What's New shows one build's notes. The entry is fixed, so a release
/// never moves the reference.
@Suite("What's New snapshots", .serialized)
@MainActor
struct WhatsNewSnapshotTests {
    private static let entry = ChangelogEntry(
        version: "1.2.0",
        build: "130",
        released: "March 2027",
        headline: "A richer Home banner, trailers for Seerr titles, and faster subtitle switching.",
        sections: [
            ChangelogSection(category: .newFeatures, changes: [
                "The banner on Home shows the year, genres, runtime and how much is left of something you've started.",
                "Titles from Seerr have a Trailer button too.",
            ]),
            ChangelogSection(category: .improvements, changes: [
                "Switching subtitles no longer pauses playback.",
            ]),
            ChangelogSection(category: .bugFixes, changes: [
                "Episodes with many subtitle tracks no longer get stuck loading.",
            ]),
        ]
    )

    #if os(tvOS)
    private static let size = Metrics.modalPanelSize
    #else
    private static let size = CGSize(width: 402, height: 874)
    #endif

    @Test func theSheetShowsTheInstalledBuild() async throws {
        try await Snapshot.verify(
            WhatsNewView(entry: Self.entry, unlistedVersion: nil),
            named: "whats-new",
            size: Self.size
        )
    }

    @Test func aBuildWithoutNotesSaysSoAboveTheNewest() async throws {
        try await Snapshot.verify(
            WhatsNewView(entry: Self.entry, unlistedVersion: "1.2.1 (131)"),
            named: "whats-new-unlisted",
            size: Self.size
        )
    }
}
