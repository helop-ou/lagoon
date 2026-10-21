import LagoonEngine
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Up Next card snapshots", .serialized)
@MainActor
struct PlayerNextUpCardSnapshotTests {
    private static let imageURL = URL(string: "https://jellyfin.snapshot.test/Items/next/Images/Thumb")!

    private static let episode = NextUpEpisode(title: "The Two Towers", subtitle: "2002", imageURL: imageURL)

    private static var hint: LocalizedStringKey {
        #if os(tvOS)
        "Select to play now · Back to stay"
        #else
        "Tap to play now"
        #endif
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: NextUpMetrics.width + 80, height: 300)
        #else
        CGSize(width: NextUpMetrics.width + 40, height: 200)
        #endif
    }

    /// The card sits over the picture. Over black its material vanishes.
    private func overVideo(_ card: PlayerNextUpCard) -> some View {
        ZStack {
            Image(uiImage: Artwork.landscape(seed: 5))
                .resizable()
                .scaledToFill()
            card
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    init() {
        ImageCache.shared.store(
            Artwork.landscape(seed: 2),
            for: Self.imageURL,
            maxPixelSize: Int(NextUpMetrics.thumbnailWidth * 2)
        )
    }

    @Test func aListCardHalfwayThroughTheCredits() async throws {
        try await Snapshot.verify(
            overVideo(PlayerNextUpCard(episode: Self.episode, showsCountdown: true, fill: 0.5, hint: Self.hint)),
            named: "next-up-list-half",
            size: Self.size
        )
    }

    @Test func aCardWithoutACountdownHasNoBar() async throws {
        try await Snapshot.verify(
            overVideo(PlayerNextUpCard(episode: Self.episode, showsCountdown: false, hint: Self.hint)),
            named: "next-up-no-countdown",
            size: Self.size
        )
    }
}
