import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Home card snapshots", .serialized)
@MainActor
struct HomeCardSnapshotTests {
    private let client: JellyfinClient = {
        let client = JellyfinClient(deviceId: "snapshot-tests")
        client.configure(serverURL: URL(string: "https://jellyfin.snapshot.test")!)
        client.activateSession(token: "token", userId: "user")
        return client
    }()

    private var landscapePixels: Int {
        ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: Snapshot.scale)
    }

    @Test func sonarrRadarrAndSeerrTitlesAreLandscapeCards() async throws {
        let items = try decodeItems(#"""
        [
            {"Name":"Abbott Elementary","Type":"Episode","ParentIndexNumber":5,"IndexNumber":3,"ProviderIds":{"SonarrEpisodeId":"1","FormattedDate":"3 Days - 2026/10/22","SonarrPoster":"/HomeScreen/CachedImage/abbott"}},
            {"Name":"Verity","Type":"Movie","ProductionYear":2026,"ProviderIds":{"RadarrMovieId":"2","FormattedDate":"1 Week - 2026/10/27","RadarrPoster":"/HomeScreen/CachedImage/verity"}},
            {"Name":"Matchbox","SourceType":"movie","PremiereDate":"2026-10-05T00:00:00.0000000Z","ProviderIds":{"Jellyseerr":"3","JellyseerrPoster":"/HomeScreen/CachedImage/matchbox"}}
        ]
        """#)
        let titles = [
            items[0].id: ExternalSeerrTitle(id: 125935, mediaType: .tv, backdropPath: "/abbott.jpg"),
            items[2].id: ExternalSeerrTitle(id: 3, mediaType: .movie, backdropPath: "/matchbox.jpg"),
        ]
        for (index, path) in ["/abbott.jpg", "/matchbox.jpg"].enumerated() {
            let url = try #require(SeerrClient.imageURL(path: path, width: landscapePixels))
            ImageCache.shared.store(Artwork.landscape(seed: index), for: url, maxPixelSize: landscapePixels)
        }
        let poster = try #require(client.serverRelativeURL("/HomeScreen/CachedImage/verity"))
        ImageCache.shared.store(Artwork.poster(seed: 7), for: poster, maxPixelSize: landscapePixels)

        try await Snapshot.verify(
            ExternalSectionRail(title: "Upcoming", items: items, seerrTitles: titles)
                .environment(\.jellyfinClient, client)
                .environment(Self.signedOutSeerr),
            named: "external-rail",
            size: Self.railSize
        )
    }

    @Test func aLandscapeCardWithProgressAndMetadata() async throws {
        let item = try decodeItem(#"""
        {"Id":"ep","Name":"Pilot","Type":"Episode","SeriesName":"Silo","SeriesId":"silo","ParentIndexNumber":1,"IndexNumber":1,"ImageTags":{"Thumb":"t"},"UserData":{"PlayedPercentage":40}}
        """#)
        let url = try #require(client.imageURL(for: item, kind: .thumb, maxWidth: landscapePixels))
        ImageCache.shared.store(Artwork.landscape(seed: 3), for: url, maxPixelSize: landscapePixels)

        try await Snapshot.verify(
            LandscapeCard(item: item, showsMetadata: true)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-progress",
            size: CGSize(width: Metrics.landscapeWidth + 40, height: Metrics.landscapeHeight + 40)
        )
    }

    /// A backdrop has no title in it, so the card draws one.
    @Test func aCardNamesATitleWhoseArtworkIsABackdrop() async throws {
        let item = try decodeItem(#"{"Id":"heist","Name":"Haunted Heist","Type":"Movie","BackdropImageTags":["b"]}"#)
        try storeLandscapeArtwork(for: item, seed: 4)

        try await Snapshot.verify(
            LandscapeCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-backdrop",
            size: Self.landscapeCardSize
        )
    }

    /// An episode's still shows a scene, not the show's name.
    @Test func aCardNamesAnEpisodeOverItsStill() async throws {
        let item = try decodeItem(#"""
        {"Id":"blackout","Name":"The One with the Blackout","Type":"Episode","SeriesName":"Friends","SeriesId":"friends","ParentIndexNumber":1,"IndexNumber":7,"ImageTags":{"Primary":"p","Thumb":"t"}}
        """#)
        try storeLandscapeArtwork(for: item, seed: 6)

        try await Snapshot.verify(
            LandscapeCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-episode-still",
            size: Self.landscapeCardSize
        )
    }

    /// A Thumb has the title printed in it, so the card adds nothing.
    @Test func aCardLeavesAThumbClean() async throws {
        let item = try decodeItem(#"{"Id":"arrival-wide","Name":"Arrival","Type":"Movie","ImageTags":{"Thumb":"t"},"BackdropImageTags":["b"]}"#)
        try storeLandscapeArtwork(for: item, seed: 5)

        try await Snapshot.verify(
            LandscapeCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-thumb",
            size: Self.landscapeCardSize
        )
    }

    /// A check in the corner, with no colour.
    @Test func aWatchedTitleCarriesACheck() async throws {
        let item = try decodeItem(#"{"Id":"seen","Name":"Arrival","Type":"Movie","ImageTags":{"Thumb":"t"},"UserData":{"Played":true,"PlayedPercentage":0}}"#)
        try storeLandscapeArtwork(for: item, seed: 8)

        try await Snapshot.verify(
            LandscapeCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-watched",
            size: Self.landscapeCardSize
        )
    }

    /// The same count a poster carries.
    @Test func aStartedSeriesCardCarriesItsUnwatchedCount() async throws {
        let item = try decodeItem(#"{"Id":"good-place-wide","Name":"The Good Place","Type":"Series","ImageTags":{"Thumb":"t"},"UserData":{"PlayedPercentage":50,"UnplayedItemCount":25}}"#)
        try storeLandscapeArtwork(for: item, seed: 9)

        try await Snapshot.verify(
            LandscapeCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-unwatched",
            size: Self.landscapeCardSize
        )
    }

    /// Its progress bar says enough.
    @Test func aWatchedTitleInProgressAgainCarriesNoCheck() async throws {
        let item = try decodeItem(#"{"Id":"again","Name":"The Station Agent","Type":"Movie","ImageTags":{"Thumb":"t"},"UserData":{"Played":true,"PlayedPercentage":32}}"#)
        try storeLandscapeArtwork(for: item, seed: 10)

        try await Snapshot.verify(
            LandscapeCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "landscape-card-watching-again",
            size: Self.landscapeCardSize
        )
    }

    /// The count sits in the corner in the theme's signal colour.
    @Test func aStartedSeriesPosterCarriesItsUnwatchedCount() async throws {
        let item = try decodeItem(#"{"Id":"good-place","Name":"The Good Place","Type":"Series","ProductionYear":2016,"ImageTags":{"Primary":"p"},"UserData":{"PlayedPercentage":50,"UnplayedItemCount":25}}"#)
        let layout = PosterLayout()
        let url = try #require(client.imageURL(for: item, kind: .primary, maxWidth: layout.imageWidth))
        ImageCache.shared.store(Artwork.poster(seed: 2), for: url, maxPixelSize: layout.imageSize)

        try await Snapshot.verify(
            PosterCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "poster-card-unwatched",
            size: CGSize(width: Metrics.posterWidth + 40, height: Metrics.posterWidth * 1.5 + 140)
        )
    }

    @Test func aPosterCardKeepsItsCaptionUnderTheArt() async throws {
        let item = try decodeItem(#"{"Id":"arrival","Name":"Arrival","Type":"Movie","ProductionYear":2016,"ImageTags":{"Primary":"p"}}"#)
        let layout = PosterLayout()
        let url = try #require(client.imageURL(for: item, kind: .primary, maxWidth: layout.imageWidth))
        ImageCache.shared.store(Artwork.poster(seed: 5), for: url, maxPixelSize: layout.imageSize)

        try await Snapshot.verify(
            PosterCard(item: item)
                .environment(\.jellyfinClient, client),
            named: "poster-card",
            size: CGSize(width: Metrics.posterWidth + 40, height: Metrics.posterWidth * 1.5 + 140)
        )
    }

    // MARK: - Fixtures

    private static var landscapeCardSize: CGSize {
        CGSize(width: Metrics.landscapeWidth + 40, height: Metrics.landscapeHeight + 40)
    }

    private func storeLandscapeArtwork(for item: MediaItem, seed: Int) throws {
        let url = try #require(client.imageURL(for: item, kind: .thumb, maxWidth: landscapePixels))
        ImageCache.shared.store(Artwork.landscape(seed: seed), for: url, maxPixelSize: landscapePixels)
    }

    private static var railSize: CGSize {
        #if os(tvOS)
        CGSize(width: 1920, height: Metrics.landscapeHeight + 200)
        #else
        CGSize(width: 402, height: Metrics.landscapeHeight + 120)
        #endif
    }

    private static let signedOutSeerr: SeerrSessionStore = {
        let defaults = UserDefaults(suiteName: "snapshot-tests")!
        return SeerrSessionStore(
            defaults: defaults,
            localData: AccountLocalData(defaults: defaults, credentials: MemoryAccountCredentials())
        )
    }()

    private func decodeItems(_ json: String) throws -> [JellyfinClient.ExternalSectionItem] {
        try JellyfinClient.decoder.decode([JellyfinClient.ExternalSectionItem].self, from: Data(json.utf8))
    }

    private func decodeItem(_ json: String) throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }
}
