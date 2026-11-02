import SwiftUI
import Testing
@testable import Lagoon

/// A Seerr title page's actions: Trailer beside Request, beside Request More
/// Seasons, and absent when TMDB has no trailer. Pages without artwork, so
/// nothing reaches the network.
@Suite("Seerr detail snapshots", .serialized)
@MainActor
struct SeerrDetailSnapshotTests {
    private static let host = "seerr.detail.snapshot.test"
    private static let seerrURL = URL(string: "https://\(host)")!
    private static let suite = "seerr-detail-snapshot-tests"

    private static let trailer = #"""
    {"site": "YouTube", "key": "featurette", "name": "Making Of", "type": "Featurette", "url": "https://www.youtube.com/watch?v=featurette1"},
    {"site": "YouTube", "key": "trailer", "name": "Official Trailer", "type": "Trailer", "url": "https://www.youtube.com/watch?v=trailer0001"}
    """#

    private static let responses: [String: String] = [
        "/api/v1/status": #"{"version":"test"}"#,
        "/api/v1/settings/public": #"{"initialized":true,"mediaServerType":2}"#,
        "/api/v1/auth/me": #"{"id":7,"username":"Viewer","permissions":32}"#,
        "/api/v1/movie/603": #"""
        {"id": 603, "title": "The Matrix", "releaseDate": "1999-03-31", "runtime": 136,
         "genres": [{"id": 28, "name": "Action"}, {"id": 878, "name": "Science Fiction"}],
         "overview": "Set in the 22nd century, The Matrix tells the story of a computer hacker who joins a group of underground insurgents fighting the vast and powerful computers who now rule the earth.",
         "relatedVideos": [\#(trailer)]}
        """#,
        "/api/v1/movie/604": #"""
        {"id": 604, "title": "The Matrix Reloaded", "releaseDate": "2003-05-15", "runtime": 138,
         "overview": "Six months after the events depicted in The Matrix, Neo has proved to be a good omen for the free humans.",
         "relatedVideos": [{"name": "Making Of", "type": "Featurette", "url": "https://www.youtube.com/watch?v=featurette1"}]}
        """#,
        "/api/v1/tv/81723": #"""
        {"id": 81723, "name": "The Gilded Age", "firstAirDate": "2022-01-24",
         "overview": "A young woman of old money joins her aunts' household in 1882 New York, where new money is changing the city.",
         "seasons": [{"id": 1, "seasonNumber": 1, "episodeCount": 9}, {"id": 2, "seasonNumber": 2, "episodeCount": 8}],
         "mediaInfo": {"status": 2, "seasons": [{"id": 10, "seasonNumber": 1, "status": 2}],
                       "requests": [{"id": 1, "status": 1, "seasons": [{"id": 20, "seasonNumber": 1}]}]},
         "relatedVideos": [\#(trailer)]}
        """#,
    ]

    private let session: SessionStore = {
        let defaults = UserDefaults(suiteName: suite)!
        let session = SessionStore(
            defaults: defaults, credentials: MemoryAccountCredentials(), stores: .isolated(defaults: defaults)
        )
        session.client.configure(serverURL: URL(string: "https://jellyfin.detail.snapshot.test")!)
        session.client.activateSession(token: "token", userId: "user")
        return session
    }()

    #if os(tvOS)
    private static let sizes = [("", CGSize(width: 1920, height: 1080))]
    #else
    private static let sizes = [("-phone", CGSize(width: 402, height: 874)), ("-wide", CGSize(width: 669, height: 951))]
    #endif

    @Test func aMovieOffersItsTrailerBesideRequest() async throws {
        try await verify(id: 603, .movie, named: "movie-trailer")
    }

    @Test func aMovieWithoutATrailerHasNoTrailerButton() async throws {
        try await verify(id: 604, .movie, named: "movie-no-trailer")
    }

    @Test func aShowOffersItsTrailerBesideRequestMoreSeasons() async throws {
        try await verify(id: 81723, .tv, named: "show-trailer")
    }

    private func verify(id: Int, _ mediaType: SeerrMediaType, named name: String) async throws {
        let seerr = try await signedInSeerr()
        let model = SeerrMediaDetailModel(mediaID: id, mediaType: mediaType)
        await model.load(client: seerr.client, jellyfin: session.client)
        try #require(model.details != nil)
        for (suffix, size) in Self.sizes {
            var page = AnyView(
                SeerrMediaDetailView(model: model)
                    .environment(session)
                    .environment(seerr)
            )
            #if os(iOS)
            let horizontal: UserInterfaceSizeClass = suffix == "-wide" ? .regular : .compact
            page = AnyView(page.environment(\.horizontalSizeClass, horizontal).environment(\.verticalSizeClass, .regular))
            #endif
            try await Snapshot.verify(page, named: name + suffix, size: size)
        }
    }

    private func signedInSeerr() async throws -> SeerrSessionStore {
        StubURLProtocol.register(host: Self.host) { request in
            let path = request.url?.path ?? ""
            let body = Self.responses[path] ?? (path.hasSuffix("/recommendations") ? #"{"results":[]}"# : "{}")
            return (200, ["Content-Type": "application/json"], Data(body.utf8))
        }
        let defaults = UserDefaults(suiteName: Self.suite)!
        let credentials = MemoryAccountCredentials()
        let account = StoredAccount(
            serverURL: URL(string: "https://jellyfin.detail.snapshot.test")!, serverName: "Fixture", userId: "user", userName: "Viewer"
        )
        defaults.set(Self.seerrURL.absoluteString, forKey: AccountLocalData.seerrServerKey(account))
        try credentials.set("cookie", for: AccountLocalData.seerrCookieKey(account, serverURL: Self.seerrURL))
        let store = SeerrSessionStore(
            client: SeerrClient(session: URLSession(configuration: StubURLProtocol.configuration())),
            defaults: defaults,
            localData: AccountLocalData(defaults: defaults, credentials: credentials)
        )
        store.select(account)
        for _ in 0..<200 where store.user == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(store.user?.canRequest(.tv) == true)
        return store
    }
}
