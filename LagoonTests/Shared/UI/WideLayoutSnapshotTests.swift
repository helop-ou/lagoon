#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The wide layouts follow the size classes, so an open iPhone Duo gets the
/// iPad's pages and a landscape Pro Max keeps the phone's. The suite runs on
/// an iPhone, so a layout that reads the idiom again draws the phone look in
/// the open-Duo references.
@Suite("Wide layout snapshots", .serialized)
@MainActor
struct WideLayoutSnapshotTests {
    /// Points, at the Duo's 3x scale.
    private static let duoOpen = CGSize(width: 669, height: 951)
    private static let phonePortrait = CGSize(width: 402, height: 874)
    private static let proMaxLandscape = CGSize(width: 956, height: 440)

    private static let backdropURL = URL(string: "https://jellyfin.snapshot.test/Items/arrival/Images/Backdrop")!
    private static let posterURL = URL(string: "https://jellyfin.snapshot.test/Items/arrival/Images/Primary")!

    private let client: JellyfinClient = {
        let client = JellyfinClient(deviceId: "snapshot-tests")
        client.configure(serverURL: URL(string: "https://jellyfin.snapshot.test")!)
        client.activateSession(token: "token", userId: "user")
        return client
    }()

    init() {
        ImageCache.shared.store(Self.smoothBackdrop, for: Self.backdropURL, maxPixelSize: Metrics.detailBackdropDecodeSize)
    }

    /// Glass refracts a hard edge behind it differently from run to run, so
    /// the backdrop has none.
    private static let smoothBackdrop: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360), format: format).image { context in
            let colors = [UIColor(hue: 0.08, saturation: 0.6, brightness: 0.8, alpha: 1).cgColor,
                          UIColor(hue: 0.62, saturation: 0.7, brightness: 0.35, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 360), options: [])
        }
    }()

    // MARK: - Detail page

    @Test func anOpenDuoGetsTheWideDetailPage() async throws {
        try await Snapshot.verify(
            detailPage(.regular, .regular),
            named: "detail-duo-open",
            size: Self.duoOpen
        )
    }

    @Test func aPortraitPhoneGetsThePosterHero() async throws {
        try await Snapshot.verify(
            detailPage(.compact, .regular),
            named: "detail-phone-portrait",
            size: Self.phonePortrait
        )
    }

    /// Regular wide, compact tall: the one-row phone layout, not the iPad's.
    @Test func aLandscapeProMaxKeepsThePhoneRow() async throws {
        try await Snapshot.verify(
            detailPage(.regular, .compact),
            named: "detail-pro-max-landscape",
            size: Self.proMaxLandscape
        )
    }

    // MARK: - Home hero

    @Test func anOpenDuoGetsTheTallHero() async throws {
        try await Snapshot.verify(
            hero(.regular, .regular),
            named: "hero-duo-open",
            size: CGSize(width: Self.duoOpen.width, height: Metrics.expandedHeroHeight + 40)
        )
    }

    @Test func aPhoneGetsTheShortHero() async throws {
        try await Snapshot.verify(
            hero(.compact, .regular),
            named: "hero-phone-portrait",
            size: CGSize(width: Self.phonePortrait.width, height: Metrics.expandedHeroHeight + 40)
        )
    }

    // MARK: - Poster grid

    @Test func anOpenDuoGridHasThreeLargeColumns() async throws {
        try await Snapshot.verify(
            try posterGrid(.regular, .regular),
            named: "grid-duo-open",
            size: CGSize(width: Self.duoOpen.width, height: 360)
        )
    }

    // MARK: - Watch Together

    @Test func watchTogetherIsAPillOnAnOpenDuoAndACircleOnAPhone() async throws {
        let syncPlay = try await joinableSyncPlay()
        let item = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"{"Id":"arrival","Name":"Arrival","Type":"Movie"}"#.utf8))
        let control = WatchTogetherControl(item: item, startPositionTicks: 0)
            .padding(Metrics.screenGutter)
            .environment(syncPlay)
        try await Snapshot.verify(
            control.environment(\.horizontalSizeClass, .regular).environment(\.verticalSizeClass, .regular),
            named: "watch-together-duo-open",
            size: CGSize(width: 300, height: 100)
        )
        try await Snapshot.verify(
            control.environment(\.horizontalSizeClass, .compact).environment(\.verticalSizeClass, .regular),
            named: "watch-together-phone",
            size: CGSize(width: 300, height: 100)
        )
    }

    // MARK: - Fixtures

    /// A server that serves SyncPlay to a viewer who may join groups.
    private func joinableSyncPlay() async throws -> SyncPlayStore {
        let host = "syncplay.snapshot.test"
        StubURLProtocol.register(host: host) { request in
            if request.url?.path.hasSuffix("/Users/Me") == true {
                return (200, [:], Data(#"{"Id":"user","Name":"Viewer","Policy":{"SyncPlayAccess":"JoinGroups"}}"#.utf8))
            }
            return (200, [:], Data("[]".utf8))
        }
        let store = SyncPlayStore()
        store.configure(client: StubURLProtocol.makeJellyfinClient(host: host, deviceId: "snapshot-tests"), accountID: "account")
        await store.refreshAvailability()
        try #require(store.availability.canJoinGroups)
        return store
    }

    private func detailPage(_ horizontal: UserInterfaceSizeClass, _ vertical: UserInterfaceSizeClass) -> some View {
        DetailPageScaffold(backdropURL: Self.backdropURL, posterURL: Self.posterURL) {
            DetailMetadataHeader(
                factTokens: ["1 h 56 min", "2016"],
                qualityTokens: ["4K", "Dolby Vision", "Atmos"],
                officialRating: "PG-13",
                genres: ["Drama", "Science Fiction", "Mystery"],
                communityRating: 7.9,
                overview: "A linguist works with the military to communicate with alien lifeforms after twelve mysterious spacecraft appear around the world."
            ) {
                TitleArtImage(
                    url: nil,
                    title: "Arrival",
                    alignment: DetailLayout.titleAlignment(horizontal, vertical)
                )
            } buttons: {
                DetailPlayActions(
                    resumes: true,
                    caption: "1 h 12 min left",
                    play: {},
                    playFromBeginning: {}
                ) {
                    TrailerButton(trailers: [
                        RemoteTrailer(url: URL(string: "https://www.youtube.com/watch?v=tFMo3UJ4B4g")!, name: "Official Trailer"),
                    ])
                }
            }
        }
        .environment(\.horizontalSizeClass, horizontal)
        .environment(\.verticalSizeClass, vertical)
    }

    private func hero(_ horizontal: UserInterfaceSizeClass, _ vertical: UserInterfaceSizeClass) -> some View {
        // No artwork: its palette arrives asynchronously.
        HeroSection(
            items: [
                HeroItem(id: "arrival", title: "Arrival", overview: "A linguist works with the military to communicate with alien lifeforms.", backdropURL: nil, logoURL: nil, route: "arrival"),
                HeroItem(id: "dune", title: "Dune", overview: "A noble family becomes embroiled in a war for control of the galaxy's most valuable asset.", backdropURL: nil, logoURL: nil, route: "dune"),
            ],
            isActive: false
        )
        .padding(.top, Metrics.Space.l)
        .environment(\.horizontalSizeClass, horizontal)
        .environment(\.verticalSizeClass, vertical)
    }

    private func posterGrid(_ horizontal: UserInterfaceSizeClass, _ vertical: UserInterfaceSizeClass) throws -> some View {
        let items = try (1...6).map { index in
            try JellyfinClient.decoder.decode(
                MediaItem.self,
                from: Data(#"{"Id":"film-\#(index)","Name":"Film \#(index)","Type":"Movie","ProductionYear":\#(2010 + index)}"#.utf8)
            )
        }
        return PosterGridView(items: items) { item in
            PosterCard(item: item)
        }
        .padding(.horizontal, Metrics.screenGutter)
        .environment(\.jellyfinClient, client)
        .environment(\.horizontalSizeClass, horizontal)
        .environment(\.verticalSizeClass, vertical)
    }
}
#endif
