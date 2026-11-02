import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Genre card snapshots", .serialized)
@MainActor
struct GenreCardSnapshotTests {
    private let session: SessionStore = {
        let defaults = UserDefaults(suiteName: "genre-card-snapshot-tests")!
        let session = SessionStore(
            defaults: defaults, credentials: MemoryAccountCredentials(), stores: .isolated(defaults: defaults)
        )
        session.client.configure(serverURL: URL(string: "https://jellyfin.snapshot.test")!)
        session.client.activateSession(token: "token", userId: "user")
        return session
    }()

    @Test func aGenreNameIsCentredOverItsArtwork() async throws {
        let item = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"heat","Name":"Heat","Type":"Movie","ImageTags":{"Thumb":"t"}}"#.utf8)
        )
        let pixels = ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: Snapshot.scale)
        let url = try #require(session.client.imageURL(for: item, kind: .thumb, maxWidth: pixels))
        ImageCache.shared.store(Artwork.landscape(seed: 1), for: url, maxPixelSize: pixels)

        try await Snapshot.verify(
            card(GenreShelfItem(id: "crime", name: "Crime", artwork: item)),
            named: "genre-card",
            size: Self.cardSize
        )
    }

    @Test func aLongGenreNameStaysCentredAndWhole() async throws {
        try await Snapshot.verify(
            card(GenreShelfItem(id: "action", name: "Action & Adventure", artwork: nil)),
            named: "genre-card-long-name",
            size: Self.cardSize
        )
    }

    // MARK: - Fixtures

    private static let cardSize = CGSize(width: Metrics.landscapeWidth + 40, height: Metrics.landscapeHeight + 40)

    private func card(_ genre: GenreShelfItem) -> some View {
        GenreCard(genre: genre, includeTypes: [.movie], identifier: "movies")
            .environment(session)
    }
}
