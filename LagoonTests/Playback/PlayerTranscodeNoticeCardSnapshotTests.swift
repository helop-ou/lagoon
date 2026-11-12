import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Transcode notice card snapshots", .serialized)
@MainActor
struct PlayerTranscodeNoticeCardSnapshotTests {
    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 600, height: 260)
        #else
        CGSize(width: 340, height: 220)
        #endif
    }

    /// The card sits over the picture. Over black its material vanishes.
    private func overVideo(_ notice: PlaybackTranscodeNotice) -> some View {
        ZStack {
            Image(uiImage: Artwork.landscape(seed: 5))
                .resizable()
                .scaledToFill()
            PlayerTranscodeNoticeCard(notice: notice, onPlayOriginal: {}, onDismiss: {})
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    @Test func anOfferToPlayTheOriginal() async throws {
        try await Snapshot.verify(
            overVideo(.capped(.auto, probedBitsPerSecond: 45_000_000, maxBitrate: 31_500_000)),
            named: "transcode-offer",
            size: Self.size
        )
    }

    @Test func informationAboutAFormat() async throws {
        try await Snapshot.verify(
            overVideo(.converting(.audio)),
            named: "transcode-information",
            size: Self.size
        )
    }
}
