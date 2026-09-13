import Foundation
import Testing
@testable import Lagoon

@Suite("Series detail view model", .serialized)
@MainActor
struct SeriesDetailViewModelTests {
    private static let onlySpecials = #"{"Items":[{"Id":"specials","Type":"Season","IndexNumber":0,"Name":"Specials"}]}"#

    private static let noUpNext = #"{"Items":[]}"#

    private static let upNextInS1 = #"{"Items":[{"Id":"s1e2","Type":"Episode","SeasonId":"s1","ParentIndexNumber":1,"IndexNumber":2}]}"#
    private static let upNextInS2 = #"{"Items":[{"Id":"s2e3","Type":"Episode","SeasonId":"s2","ParentIndexNumber":2,"IndexNumber":3}]}"#
    private static let upNextInUnknownSeason = #"{"Items":[{"Id":"missing-e1","Type":"Episode","SeasonId":"missing","ParentIndexNumber":9,"IndexNumber":1}]}"#

    private static let s1Episodes = #"""
    {"Items":[
        {"Id":"s1e1","Type":"Episode","SeasonId":"s1","ParentIndexNumber":1,"IndexNumber":1},
        {"Id":"s1e2","Type":"Episode","SeasonId":"s1","ParentIndexNumber":1,"IndexNumber":2}
    ]}
    """#
    private static let s2Episodes = #"""
    {"Items":[
        {"Id":"s2e1","Type":"Episode","SeasonId":"s2","ParentIndexNumber":2,"IndexNumber":1},
        {"Id":"s2e2","Type":"Episode","SeasonId":"s2","ParentIndexNumber":2,"IndexNumber":2},
        {"Id":"s2e3","Type":"Episode","SeasonId":"s2","ParentIndexNumber":2,"IndexNumber":3}
    ]}
    """#

    @Test func opensOnTheUpNextEpisodesSeason() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(nextUp: Self.upNextInS2, episodes: ["s2": Self.s2Episodes])
        let viewModel = SeriesDetailViewModel()

        await viewModel.load(client: client, seriesId: "show")

        #expect(viewModel.selectedSeasonId == "s2")
        #expect(viewModel.episodes.map(\.id) == ["s2e1", "s2e2", "s2e3"])
        #expect(viewModel.upNext?.id == "s2e3")
        let episodesURL = try #require(SeriesDetailURLProtocol.urls.last)
        #expect(episodesURL.path == "/Shows/show/Episodes")
        #expect(query(episodesURL, "SeasonId") == "s2")
    }

    @Test func aFinishedShowOpensOnItsFirstRegularSeasonAndOffersItsFirstEpisode() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(nextUp: Self.noUpNext, episodes: ["s1": Self.s1Episodes])
        let viewModel = SeriesDetailViewModel()

        await viewModel.load(client: client, seriesId: "show")

        #expect(viewModel.selectedSeasonId == "s1")
        #expect(viewModel.upNext == nil)
        #expect(viewModel.firstEpisode?.id == "s1e1")
    }

    @Test func aShowWithOnlySpecialsStillOpensSomewhere() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(seasons: Self.onlySpecials, nextUp: Self.noUpNext)
        let viewModel = SeriesDetailViewModel()

        await viewModel.load(client: client, seriesId: "show")

        #expect(viewModel.selectedSeasonId == "specials")
    }

    @Test func anUpNextInAnUnknownSeasonFallsBackToTheFirstRegularSeason() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(nextUp: Self.upNextInUnknownSeason)
        let viewModel = SeriesDetailViewModel()

        await viewModel.load(client: client, seriesId: "show")

        #expect(viewModel.selectedSeasonId == "s1")
    }

    @Test func afterPlaybackTheRailFollowsTheNewUpNextSeason() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(nextUp: Self.upNextInS1, episodes: ["s1": Self.s1Episodes, "s2": Self.s2Episodes])
        let viewModel = SeriesDetailViewModel()
        await viewModel.load(client: client, seriesId: "show")
        #expect(viewModel.selectedSeasonId == "s1")

        SeriesDetailURLProtocol.set(nextUp: Self.upNextInS2)
        await viewModel.reloadUserData(client: client, seriesId: "show")
        await viewModel.followUpNext(client: client, seriesId: "show")

        #expect(viewModel.selectedSeasonId == "s2")
        #expect(viewModel.episodes.map(\.id) == ["s2e1", "s2e2", "s2e3"])
    }

    @Test func followUpNextLeavesAVisibleSeasonAlone() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(nextUp: Self.upNextInS1, episodes: ["s1": Self.s1Episodes])
        let viewModel = SeriesDetailViewModel()
        await viewModel.load(client: client, seriesId: "show")
        #expect(viewModel.selectedSeasonId == "s1")
        let episodeRequestsBefore = SeriesDetailURLProtocol.urls.filter { $0.path == "/Shows/show/Episodes" }.count

        await viewModel.followUpNext(client: client, seriesId: "show")

        #expect(SeriesDetailURLProtocol.urls.filter { $0.path == "/Shows/show/Episodes" }.count == episodeRequestsBefore)
        #expect(viewModel.selectedSeasonId == "s1")
    }

    @Test func followUpNextDoesNothingOnceTheShowIsFinished() async throws {
        let client = makeClient()
        SeriesDetailURLProtocol.set(nextUp: Self.upNextInS2, episodes: ["s2": Self.s2Episodes])
        let viewModel = SeriesDetailViewModel()
        await viewModel.load(client: client, seriesId: "show")
        #expect(viewModel.selectedSeasonId == "s2")

        SeriesDetailURLProtocol.set(nextUp: Self.noUpNext)
        await viewModel.reloadUserData(client: client, seriesId: "show")
        await viewModel.followUpNext(client: client, seriesId: "show")

        #expect(viewModel.selectedSeasonId == "s2")
        #expect(viewModel.firstEpisode?.id == "s2e1")
    }

    private func makeClient() -> JellyfinClient {
        SeriesDetailURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeriesDetailURLProtocol.self]
        let client = JellyfinClient(deviceId: "series-detail-tests", sessionConfiguration: configuration)
        client.configure(serverURL: URL(string: "https://series-tests.test")!)
        client.activateSession(token: "token", userId: "user")
        return client
    }

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

private nonisolated final class SeriesDetailURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var urls: [URL] = []
        var show = #"{"Id":"show","Type":"Series"}"#
        var seasons = #"""
        {"Items":[
            {"Id":"specials","Type":"Season","IndexNumber":0,"Name":"Specials"},
            {"Id":"s1","Type":"Season","IndexNumber":1},
            {"Id":"s2","Type":"Season","IndexNumber":2}
        ]}
        """#
        var nextUp = #"{"Items":[]}"#
        var episodesBySeasonId: [String: String] = [:]
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    static var urls: [URL] { lock.withLock { state.urls } }

    static func reset() { lock.withLock { state = State() } }

    static func set(show: String? = nil, seasons: String? = nil, nextUp: String? = nil, episodes: [String: String]? = nil) {
        lock.withLock {
            if let show { state.show = show }
            if let seasons { state.seasons = seasons }
            if let nextUp { state.nextUp = nextUp }
            if let episodes { state.episodesBySeasonId.merge(episodes) { _, new in new } }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "series-tests.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.state.urls.append(url) }
        respond()
    }

    private func respond() {
        guard let url = request.url else { return }
        let body = Self.lock.withLock { () -> String in
            switch url.path {
            case "/Users/user/Items/show": return Self.state.show
            case "/Shows/show/Seasons": return Self.state.seasons
            case "/Shows/NextUp": return Self.state.nextUp
            case "/Shows/show/Episodes":
                let seasonId = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "SeasonId" }?.value
                return seasonId.flatMap { Self.state.episodesBySeasonId[$0] } ?? #"{"Items":[]}"#
            default: return #"{"Items":[]}"#
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
