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

@MainActor
private enum Artwork {
    static func landscape(seed: Int) -> UIImage { draw(CGSize(width: 640, height: 360), seed: seed) }
    static func poster(seed: Int) -> UIImage { draw(CGSize(width: 400, height: 600), seed: seed) }

    private static func draw(_ size: CGSize, seed: Int) -> UIImage {
        let hues: [CGFloat] = [0.55, 0.08, 0.33, 0.78, 0.95, 0.15, 0.62, 0.45]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let top = UIColor(hue: hues[seed % hues.count], saturation: 0.6, brightness: 0.8, alpha: 1)
            let bottom = UIColor(hue: hues[(seed + 3) % hues.count], saturation: 0.7, brightness: 0.35, alpha: 1)
            top.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height / 2)))
            bottom.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            UIColor.white.withAlphaComponent(0.85).setFill()
            let side = min(size.width, size.height) / 3
            context.cgContext.fillEllipse(in: CGRect(
                x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side
            ))
        }
    }
}
