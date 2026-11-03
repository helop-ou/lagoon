import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The hero's text column: the info line, the ratings and a started title's
/// progress on every platform, and the synopsis on Apple TV only.
@Suite("Hero snapshots", .serialized)
@MainActor
struct HeroSnapshotTests {
    private static let backdropURL = URL(string: "https://jellyfin.snapshot.test/Items/hero/Images/Backdrop")!
    private static let logoURL = URL(string: "https://jellyfin.snapshot.test/Items/hero/Images/Logo")!

    /// A wide wordmark, the shape that grew too large on phones.
    private static let wideLogo: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 110), format: format).image { context in
            UIColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1).setFill()
            for index in 0..<6 {
                context.fill(CGRect(x: index * 100 + 8, y: 8, width: 84, height: 94))
            }
        }
    }()

    #if os(tvOS)
    private static let sizes = [("", CGSize(width: 1920, height: Metrics.heroHeight + 80))]
    #else
    private static let sizes = [
        ("-phone", CGSize(width: 402, height: 340)),
        ("-wide", CGSize(width: 1024, height: 480)),
    ]
    #endif

    init() {
        ImageCache.shared.store(
            Artwork.landscape(seed: 1), for: Self.backdropURL, maxPixelSize: Metrics.detailBackdropDecodeSize
        )
        ImageCache.shared.store(
            Self.wideLogo,
            for: Self.logoURL,
            maxPixelSize: ArtworkSizing.pixels(for: Metrics.logoMaxWidth, displayScale: Snapshot.scale)
        )
    }

    /// Phones cap a wordmark's width as well as its height.
    @Test func aWideLogoKeepsToItsBox() async throws {
        try await verify(hero(
            title: "Resident Evil",
            facts: ["2026", "Horror", "Science Fiction", "1 h 33 min"],
            ageRating: "R",
            starRating: 7.3,
            logoURL: Self.logoURL
        ), named: "wide-logo")
    }

    @Test func aFilmShowsItsInfoLineAndRatings() async throws {
        try await verify(hero(
            title: "Arrival",
            facts: ["2016", "Science Fiction", "Drama", "1 h 56 min"],
            ageRating: "PG-13",
            starRating: 7.9
        ), named: "film")
    }

    @Test func aStartedEpisodeShowsItsProgress() async throws {
        try await verify(hero(
            title: "Silo",
            facts: ["S2 E5", "Machines"],
            ageRating: "TV-MA",
            starRating: 8.1,
            progress: 0.4,
            timeRemaining: "28 min left"
        ), named: "episode-progress")
    }

    /// Seerr has no age rating or progress, and a title with no score shows
    /// no ratings row at all.
    @Test func missingPiecesLeaveNoGap() async throws {
        try await verify(hero(title: "Matchbox", facts: ["2026"]), named: "sparse")
    }

    private func hero(
        title: String,
        facts: [String],
        ageRating: String? = nil,
        starRating: Double? = nil,
        progress: Double? = nil,
        timeRemaining: String? = nil,
        logoURL: URL? = nil
    ) -> HeroItem<String> {
        HeroItem(
            id: title,
            title: title,
            overview: "A linguist works with the military to communicate with alien lifeforms after twelve mysterious spacecraft appear around the world.",
            backdropURL: Self.backdropURL,
            logoURL: logoURL,
            route: title,
            facts: facts,
            ageRating: ageRating,
            starRating: starRating,
            progress: progress,
            timeRemaining: timeRemaining
        )
    }

    private func verify(
        _ item: HeroItem<String>,
        named name: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for (suffix, size) in Self.sizes {
            try await Snapshot.verify(
                // A second slide, so the page dots show beside the text.
                HeroSection(items: [item, hero(title: "Next", facts: [])], isActive: false)
                    #if os(iOS)
                    .environment(\.horizontalSizeClass, suffix == "-wide" ? .regular : .compact)
                    .environment(\.verticalSizeClass, .regular)
                    #endif
                    .padding(.vertical, Metrics.Space.xxl),
                named: name + suffix,
                size: size,
                sourceLocation: sourceLocation
            )
        }
    }
}
