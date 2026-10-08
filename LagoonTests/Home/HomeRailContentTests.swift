import Foundation
import Testing
@testable import Lagoon

@Suite("Home rail content", .serialized)
@MainActor
struct HomeRailContentTests {
    @Test func nextUpRequestsUnstartedEpisodesAndRejectsProgressDefensively() async throws {
        let client = makeClient()
        HomeRailURLProtocol.set(nextUp: #"""
        {"Items":[
            {"Id":"ready","Type":"Episode","UserData":{"PlaybackPositionTicks":0,"PlayedPercentage":0,"Played":false}},
            {"Id":"started","Type":"Episode","UserData":{"PlaybackPositionTicks":1}},
            {"Id":"percentage-only","Type":"Episode","UserData":{"PlayedPercentage":0.1}},
            {"Id":"finished","Type":"Episode","UserData":{"Played":true}},
            {"Id":"no-user-data","Type":"Episode"}
        ]}
        """#)

        let items = try await client.nextUp(limit: 7)

        #expect(items.map(\.id) == ["ready", "no-user-data"])
        let url = try #require(HomeRailURLProtocol.urls.first)
        #expect(url.path == "/Shows/NextUp")
        #expect(query(url, "UserId") == "user")
        #expect(query(url, "Limit") == "7")
        #expect(query(url, "EnableResumable") == "false")
        #expect(query(url, "EnableRewatching") == "false")
    }

    @Test func continueWatchingAndSeriesPlayStillResume() async throws {
        let client = makeClient()
        let started = #"{"Items":[{"Id":"started","Type":"Episode","UserData":{"PlaybackPositionTicks":100}}]}"#
        HomeRailURLProtocol.set(nextUp: started, resume: started)

        #expect(try await client.resumeItems().map(\.id) == ["started"])
        #expect(try await client.nextUpEpisode(seriesId: "show")?.id == "started")
        let url = try #require(HomeRailURLProtocol.urls.last)
        #expect(query(url, "seriesId") == "show")
        #expect(query(url, "EnableResumable") == "true")
    }

    @Test func latestShowsResolveRealParentsOnceAndKeepFirstAdditionOrder() async throws {
        let client = makeClient()
        HomeRailURLProtocol.set(latest: #"""
        [
            {"Id":"a-episode","Type":"Episode","SeriesId":"a","ImageTags":{"Primary":"episode-still"}},
            {"Id":"b-episode","Type":"Episode","SeriesId":"b"},
            {"Id":"c-season","Type":"Season","SeriesId":"c"},
            {"Id":"a-episode-2","Type":"Episode","SeriesId":"a"},
            {"Id":"b","Type":"Series","Name":"Show B"},
            {"Id":"b","Type":"Series","Name":"Duplicate B"}
        ]
        """#, parents: #"""
        {"Items":[
            {"Id":"c","Type":"Series","Name":"Show C"},
            {"Id":"a","Type":"Series","Name":"Show A","Overview":"Series overview","ImageTags":{"Thumb":"series-thumb"},"BackdropImageTags":["series-backdrop"]},
            {"Id":"a","Type":"Series","Name":"Duplicate A"},
            {"Id":"unrelated","Type":"Series"}
        ]}
        """#)

        let shows = try await client.latestSeries(parentId: "shows", limit: 9)

        #expect(shows.map(\.id) == ["a", "b", "c"])
        #expect(shows.allSatisfy { $0.type == .series })
        #expect(shows.first?.name == "Show A")
        #expect(shows.first?.overview == "Series overview")
        #expect(shows.first?.imageTags == ["Thumb": "series-thumb"])
        #expect(shows.first?.backdropImageTags == ["series-backdrop"])
        #expect(shows[1].name == "Show B")
        #expect(HomeRailURLProtocol.urls.count == 2)
        let latestURL = try #require(HomeRailURLProtocol.urls.first)
        #expect(query(latestURL, "ParentId") == "shows")
        #expect(query(latestURL, "Limit") == "9")
        #expect(query(latestURL, "IncludeItemTypes") == nil)
        let lookup = try #require(HomeRailURLProtocol.urls.last)
        #expect(lookup.path == "/Users/user/Items")
        #expect(query(lookup, "Ids") == "a,c")
        #expect(query(lookup, "IncludeItemTypes") == "Series")
        #expect(query(lookup, "Limit") == "2")
        #expect(query(lookup, "Fields") == JellyfinClient.defaultFields)
    }

    @Test func missingOrInvalidParentsNeverFallBackToEpisodeCards() async throws {
        let client = makeClient()
        HomeRailURLProtocol.set(latest: #"""
        [
            {"Id":"orphan","Type":"Episode"},
            {"Id":"empty-parent","Type":"Episode","SeriesId":""},
            {"Id":"removed-episode","Type":"Episode","SeriesId":"removed"},
            {"Id":"invalid-episode","Type":"Episode","SeriesId":"invalid"},
            {"Id":"movie","Type":"Movie"},
            {"Id":"valid","Type":"Series"}
        ]
        """#, parents: #"{"Items":[{"Id":"invalid","Type":"Episode"}]}"#)

        #expect(try await client.latestSeries(parentId: "shows").map(\.id) == ["valid"])
    }

    @Test(arguments: ["[]", #"[{"Id":"show","Type":"Series"},{"Id":"show","Type":"Series"}]"#])
    func emptyOrAlreadyGroupedResultsNeedNoParentRequest(latest: String) async throws {
        let client = makeClient()
        HomeRailURLProtocol.set(latest: latest)

        let shows = try await client.latestSeries(parentId: "shows")

        #expect(shows.map(\.id) == (latest == "[]" ? [] : ["show"]))
        #expect(HomeRailURLProtocol.urls.count == 1)
    }

    @Test func homeNormalizesOnLoadAndRefreshAndRetainsTheRailOnLookupFailure() async throws {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(latest: #"[{"Id":"episode","Type":"Episode","SeriesId":"show"}]"#,
                                parents: #"{"Items":[{"Id":"show","Type":"Series","Name":"Original"}]}"#)

        await model.load(client: client, accountID: "account")
        #expect(model.latestRails.first?.items.first?.type == .series)
        #expect(model.latestRails.first?.items.first?.name == "Original")
        // The same fixture in a movie library is deliberately not normalized.
        #expect(model.latestRails.last?.items.first?.id == "episode")

        HomeRailURLProtocol.set(parents: #"{"Items":[{"Id":"show","Type":"Series","Name":"Refreshed"}]}"#)
        await model.refreshServerContent(client: client, homeSectionPreferences: HomeSectionPreferenceValues())
        #expect(model.latestRails.first?.items.first?.name == "Refreshed")

        HomeRailURLProtocol.set(parentStatus: 503)
        await model.refreshServerContent(client: client, homeSectionPreferences: HomeSectionPreferenceValues())
        #expect(model.latestRails.first?.items.first?.name == "Refreshed")

        HomeRailURLProtocol.set(parents: #"{"Items":[]}"#, parentStatus: 200)
        await model.refreshServerContent(client: client, homeSectionPreferences: HomeSectionPreferenceValues())
        #expect(model.latestRails.first?.items.isEmpty == true)
    }

    @Test func aLoadSupersededByAnAccountSwitchPublishesNothing() async {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(resume: #"{"Items":[{"Id":"first","Type":"Movie"}]}"#)
        HomeRailURLProtocol.hold("latest")
        defer { HomeRailURLProtocol.release() }

        let stale = Task { await model.load(client: client, accountID: "first") }
        while !HomeRailURLProtocol.hasPending { await Task.yield() }
        // Keep the first load parked so its results land after the second's.
        HomeRailURLProtocol.hold("none")
        HomeRailURLProtocol.set(resume: #"{"Items":[{"Id":"second","Type":"Movie"}]}"#)
        await model.load(client: client, accountID: "second")
        #expect(model.resume.map(\.id) == ["second"])

        HomeRailURLProtocol.release()
        await stale.value

        #expect(model.resume.map(\.id) == ["second"])
        #expect(!model.isLoading)
        #expect(model.errorMessage == nil)
        // Refresh joins its discovery tasks, so none leak into another fixture.
        await model.refreshServerContent(client: client, homeSectionPreferences: .init())
    }

    @Test(arguments: ["latest", "parents"])
    func switchingAccountsCannotMixLatestAndParentRecords(heldStage: String) async throws {
        let client = makeClient()
        HomeRailURLProtocol.set(latest: #"[{"Id":"episode","Type":"Episode","SeriesId":"show"}]"#,
                                parents: #"{"Items":[{"Id":"show","Type":"Series"}]}"#)
        HomeRailURLProtocol.hold(heldStage)
        let request = Task { try await client.latestSeries(parentId: "shows") }
        while !HomeRailURLProtocol.hasPending { await Task.yield() }
        client.activateSession(token: "different-token", userId: "different-user")
        HomeRailURLProtocol.release()

        do {
            _ = try await request.value
            Issue.record("Obsolete account results must be discarded")
        } catch is CancellationError {
            #expect(HomeRailURLProtocol.urls.count == (heldStage == "latest" ? 1 : 2))
        }
        #expect(HomeRailURLProtocol.urls.allSatisfy { $0.path.hasPrefix("/Users/user/") })
    }

    @Test func cancelledLatestDoesNotStartNetworkWork() async {
        let client = makeClient()
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.latestSeries(parentId: "shows")
        }
        do {
            _ = try await request.value
            Issue.record("Cancelled work must not return a rail")
        } catch is CancellationError {
            #expect(HomeRailURLProtocol.urls.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func slowTopTenScanDoesNotDelayNativeCuratedShelves() async throws {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(discoveryItems: #"""
        [
            {"Id":"a","Type":"Movie","ProviderIds":{"Tmdb":"1"}},
            {"Id":"b","Type":"Movie","ProviderIds":{"Tmdb":"2"}},
            {"Id":"c","Type":"Movie","ProviderIds":{"Tmdb":"3"}},
            {"Id":"d","Type":"Movie","ProviderIds":{"Tmdb":"4"}}
        ]
        """#)
        HomeRailURLProtocol.hold("topTen")
        defer { HomeRailURLProtocol.release() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRailURLProtocol.self]
        let seerr = SeerrClient(session: URLSession(configuration: configuration))
        seerr.configure(serverURL: try #require(URL(string: "https://home-rails.test")))
        seerr.setSessionCookie("fixture")

        await model.load(client: client, accountID: "account", seerr: seerr)
        let deadline = ContinuousClock.now + .seconds(5)
        while (!HomeRailURLProtocol.hasPending
                || model.curatedRails[HomeCuratedRows.ID.highlyRated] == nil),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(HomeRailURLProtocol.hasPending)
        #expect(!model.isLoading)
        #expect(model.curatedRails[HomeCuratedRows.ID.highlyRated]?.items.count == 4)
        #expect(model.curatedRails[HomeCuratedRows.ID.topMovies] == nil)

        HomeRailURLProtocol.release()
        // Refresh joins its discovery tasks, so none leak into another fixture.
        await model.refreshServerContent(client: client, homeSectionPreferences: .init(), seerr: seerr)
        #expect(model.curatedRails[HomeCuratedRows.ID.topMovies]?.items.map(\.id) == ["d", "c", "b", "a"])
        #expect(model.curatedRails[HomeCuratedRows.ID.topShows] == nil)
    }

    @Test func aTopTenScanForASeerrSessionThatEndedPublishesNothing() async throws {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(discoveryItems: Self.matchableMovies)
        HomeRailURLProtocol.hold("topTen")
        defer { HomeRailURLProtocol.release() }
        let seerr = try makeSeerr()

        await model.load(client: client, accountID: "account", seerr: seerr)
        let discovery = model.discoveryTasks
        while !HomeRailURLProtocol.hasPending { await Task.yield() }
        // Signed out of Seerr while the library scan was still running.
        seerr.clear()
        HomeRailURLProtocol.release()
        for task in discovery { await task.value }

        #expect(model.curatedRails[HomeCuratedRows.ID.highlyRated]?.items.count == 4)
        #expect(model.curatedRails[HomeCuratedRows.ID.topMovies] == nil)
    }

    @Test func switchingAccountsClearsEveryShelfEvenWhenTheNewLoadFails() async throws {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(
            discoveryItems: Self.matchableMovies,
            collections: #"[{"Id":"box","Type":"BoxSet","Name":"Box","ChildCount":2,"BackdropImageTags":["b"]}]"#,
            genres: #"[{"Id":"drama","Name":"Drama"}]"#
        )
        await model.load(client: client, accountID: "first")
        for task in model.discoveryTasks { await task.value }
        #expect(!model.curatedRails.isEmpty)
        #expect(model.collections.map(\.id) == ["box"])
        #expect(!model.movieGenreShelf.isEmpty)
        #expect(!model.heroItems.isEmpty)

        HomeRailURLProtocol.set(viewsStatus: 500)
        await model.load(client: client, accountID: "second")

        #expect(model.errorMessage != nil)
        #expect(model.curatedRails.isEmpty)
        #expect(model.collections.isEmpty)
        #expect(model.movieGenreShelf.isEmpty)
        #expect(model.showGenreShelf.isEmpty)
        #expect(model.heroItems.isEmpty)
    }

    @Test func collectionsStillLoadingForTheLastAccountNeverReachTheNextOne() async throws {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(
            collections: #"[{"Id":"box","Type":"BoxSet","Name":"Box","ChildCount":2,"BackdropImageTags":["b"]}]"#
        )
        HomeRailURLProtocol.hold("collections")
        defer { HomeRailURLProtocol.release() }

        await model.load(client: client, accountID: "first")
        let stale = model.discoveryTasks
        while !HomeRailURLProtocol.hasPending { await Task.yield() }
        HomeRailURLProtocol.set(viewsStatus: 500)
        await model.load(client: client, accountID: "second")
        HomeRailURLProtocol.release()
        for task in stale { await task.value }

        #expect(model.collections.isEmpty)
    }

    @Test func pluginRailsAreFiledUnderTheSectionHomeDrawsThemFor() async throws {
        let client = makeClient()
        let model = HomeViewModel()
        HomeRailURLProtocol.set(
            homeSections: #"[{"Section":"MyList","DisplayText":"My List"}]"#,
            homeSectionItems: #"[{"Id":"listed","Type":"Movie"}]"#
        )

        await model.load(client: client, accountID: "account")

        #expect(model.pluginRails.map(\.title) == ["My List"])
        #expect(model.pluginRails.map { HomeRowID.section(forPluginRailID: $0.id) } == ["MyList"])
    }

    /// Four movies the Top 10 stub's TMDB ids match, eligible for the hero,
    /// with a genre for the genre shelf.
    private static let matchableMovies = #"""
    [
        {"Id":"a","Type":"Movie","Overview":"A","Genres":["Drama"],"BackdropImageTags":["a"],"ProviderIds":{"Tmdb":"1"}},
        {"Id":"b","Type":"Movie","Overview":"B","Genres":["Drama"],"BackdropImageTags":["b"],"ProviderIds":{"Tmdb":"2"}},
        {"Id":"c","Type":"Movie","Overview":"C","Genres":["Drama"],"BackdropImageTags":["c"],"ProviderIds":{"Tmdb":"3"}},
        {"Id":"d","Type":"Movie","Overview":"D","Genres":["Drama"],"BackdropImageTags":["d"],"ProviderIds":{"Tmdb":"4"}}
    ]
    """#

    private func makeSeerr() throws -> SeerrClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRailURLProtocol.self]
        let seerr = SeerrClient(session: URLSession(configuration: configuration))
        seerr.configure(serverURL: try #require(URL(string: "https://home-rails.test")))
        seerr.setSessionCookie("fixture")
        return seerr
    }

    private func makeClient() -> JellyfinClient {
        HomeRailURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeRailURLProtocol.self]
        let client = JellyfinClient(deviceId: "home-rail-tests", sessionConfiguration: configuration)
        client.configure(serverURL: URL(string: "https://home-rails.test")!)
        client.activateSession(token: "token", userId: "user")
        return client
    }

    private func query(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

private nonisolated final class HomeRailURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var urls: [URL] = []
        var latest = "[]"
        var parents = #"{"Items":[]}"#
        var nextUp = #"{"Items":[]}"#
        var resume = #"{"Items":[]}"#
        var parentStatus = 200
        var discoveryItems = "[]"
        var viewsStatus = 200
        var collections = "[]"
        var genres = "[]"
        var homeSections = "[]"
        var homeSectionItems = "[]"
        var heldStage: String?
        var pending: [HomeRailURLProtocol] = []
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    static var urls: [URL] { lock.withLock { state.urls } }
    static var hasPending: Bool { lock.withLock { !state.pending.isEmpty } }

    static func reset() { lock.withLock { state = State() } }

    static func set(latest: String? = nil, parents: String? = nil, nextUp: String? = nil,
                    resume: String? = nil, parentStatus: Int? = nil, discoveryItems: String? = nil,
                    viewsStatus: Int? = nil, collections: String? = nil, genres: String? = nil,
                    homeSections: String? = nil, homeSectionItems: String? = nil) {
        lock.withLock {
            if let viewsStatus { state.viewsStatus = viewsStatus }
            if let collections { state.collections = collections }
            if let genres { state.genres = genres }
            if let homeSections { state.homeSections = homeSections }
            if let homeSectionItems { state.homeSectionItems = homeSectionItems }
            if let latest { state.latest = latest }
            if let parents { state.parents = parents }
            if let nextUp { state.nextUp = nextUp }
            if let resume { state.resume = resume }
            if let parentStatus { state.parentStatus = parentStatus }
            if let discoveryItems { state.discoveryItems = discoveryItems }
        }
    }

    static func hold(_ stage: String) { lock.withLock { state.heldStage = stage } }

    static func release() {
        let pending = lock.withLock {
            let pending = state.pending
            state.pending = []
            state.heldStage = nil
            return pending
        }
        for request in pending { request.respond() }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "home-rails.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let held = Self.lock.withLock {
            Self.state.urls.append(url)
            let stage = Self.stage(of: url)
            if stage == Self.state.heldStage {
                Self.state.pending.append(self)
                return true
            }
            return false
        }
        if !held { respond() }
    }

    private static func stage(of url: URL) -> String {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name == "Fields" && $0.value?.hasPrefix("ProviderIds,") == true }) {
            return "topTen"
        }
        if query.contains(where: { $0.name == "IncludeItemTypes" && $0.value == "BoxSet" }) {
            return "collections"
        }
        return url.path.hasSuffix("/Latest") ? "latest" : "parents"
    }

    private func respond() {
        guard let url = request.url else { return }
        let (body, status) = Self.lock.withLock { () -> (String, Int) in
            switch url.path {
            case "/Users/user/Views":
                return (#"{"Items":[{"Id":"shows","Type":"CollectionFolder","CollectionType":"tvshows"},{"Id":"movies","Type":"CollectionFolder","CollectionType":"movies"}]}"#, Self.state.viewsStatus)
            case "/Genres": return (#"{"Items":\#(Self.state.genres)}"#, 200)
            case "/HomeScreen/Sections": return (#"{"Items":\#(Self.state.homeSections)}"#, 200)
            case let path where path.hasPrefix("/HomeScreen/Section/"):
                return (#"{"Items":\#(Self.state.homeSectionItems)}"#, 200)
            case "/Users/user/Items/Latest": return (Self.state.latest, 200)
            case "/Shows/NextUp": return (Self.state.nextUp, 200)
            case "/Users/user/Items/Resume": return (Self.state.resume, 200)
            case "/Users/user/Items":
                if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "Ids" }) == true {
                    return (Self.state.parents, Self.state.parentStatus)
                }
                if Self.stage(of: url) == "collections" {
                    return (#"{"Items":\#(Self.state.collections)}"#, 200)
                }
                return (#"{"Items":\#(Self.state.discoveryItems)}"#, 200)
            case "/api/v1/discover/trending", "/api/v1/discover/movies", "/api/v1/discover/tv":
                return (#"{"page":1,"totalPages":1,"totalResults":4,"results":[{"id":4,"mediaType":"movie"},{"id":3,"mediaType":"movie"},{"id":2,"mediaType":"movie"},{"id":1,"mediaType":"movie"}]}"#, 200)
            default: return (#"{"Items":[]}"#, 200)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
