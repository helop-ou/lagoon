import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Quality offer card snapshots", .serialized)
@MainActor
struct PlayerQualityOfferCardSnapshotTests {
    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 600, height: 260)
        #else
        CGSize(width: 340, height: 220)
        #endif
    }

    @Test func theOfferOverVideo() async throws {
        try await Snapshot.verify(
            ZStack {
                Image(uiImage: Artwork.landscape(seed: 5))
                    .resizable()
                    .scaledToFill()
                PlayerQualityOfferCard(onAccept: {}, onDismiss: {})
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .clipped(),
            named: "quality-offer",
            size: Self.size
        )
    }
}
