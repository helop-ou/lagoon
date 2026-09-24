import Foundation
import Testing
@testable import Lagoon

@Suite("Server foreground sync", .serialized)
@MainActor
struct ServerSyncTests {
    @Test func refreshClockAdvancesOnlyWhenRequested() {
        let sync = ServerSyncState()

        #expect(sync.generation == 0)
        sync.requestRefresh()
        #expect(sync.generation == 1)
        sync.requestRefresh()
        #expect(sync.generation == 2)
    }

    @Test func idleRefreshPolicyUsesFiveMinutesAndAllowsADebugOverride() {
        let suiteName = "ServerRefreshPolicyTests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(ServerRefreshPolicy.intervalSeconds(defaults: defaults) == 300)
        defaults.set(0.25, forKey: "debug.serverSyncIntervalSeconds")
        #expect(ServerRefreshPolicy.intervalSeconds(defaults: defaults) == 0.25)
    }

    @Test func manualRefreshRoutesOnlyToTheVisibleDestination() {
        let sync = ServerSyncState()

        sync.activate(.home)
        sync.requestManualRefresh(for: .discover)
        #expect(sync.manualRefreshGeneration == 0)

        sync.requestManualRefresh(for: .home)
        #expect(sync.manualRefreshGeneration == 1)
        #expect(sync.manualRefreshTarget == .home)

        sync.beginRefresh(.home)
        #expect(sync.isRefreshing(.home))
        sync.endRefresh(.home)
        #expect(!sync.isRefreshing(.home))

        sync.deactivate(.discover)
        #expect(sync.activeTarget == .home)
        sync.deactivate(.home)
        #expect(sync.activeTarget == nil)
    }

    @Test func homeReconcilesServerBackedRailsWithoutASecondInitialLoad() async {
        let client = makeClient()
        let model = HomeViewModel()

        ServerSyncFixture.setRevision(1)
        await model.load(client: client, accountID: "account")
        #expect(model.resume.first?.id == "resume-1")
        #expect(model.nextUp.first?.id == "next-1")
        #expect(model.favorites.first?.id == "favorite-1")
        #expect(model.latestRails.first?.items.first?.id == "latest-1")

        ServerSyncFixture.setRevision(2)
        await model.refreshServerContent(
            client: client,
            homeSectionPreferences: HomeSectionPreferenceValues()
        )

        #expect(model.resume.first?.id == "resume-2")
        #expect(model.nextUp.first?.id == "next-2")
        #expect(model.favorites.first?.id == "favorite-2")
        #expect(model.latestRails.first?.items.first?.id == "latest-2")
    }

    @Test func aFailedForegroundRefreshKeepsTheLastGoodHome() async {
        let client = makeClient()
        let model = HomeViewModel()

        await model.load(client: client, accountID: "account")
        ServerSyncFixture.setFailing(true)
        await model.refreshServerContent(
            client: client,
            homeSectionPreferences: HomeSectionPreferenceValues()
        )

        #expect(model.resume.first?.id == "resume-1")
        #expect(model.nextUp.first?.id == "next-1")
        #expect(model.favorites.first?.id == "favorite-1")
        #expect(model.latestRails.first?.items.first?.id == "latest-1")
        #expect(model.errorMessage == nil)
    }

    @Test func emptyResumeClearsEvenWhenNextUpFails() async {
        let client = makeClient()
        let model = HomeViewModel()
        await model.load(client: client, accountID: "account")
        #expect(!model.resume.isEmpty)
        ServerSyncFixture.setRevision(0)
        await model.refreshProgress(client: client)
        #expect(model.resume.isEmpty)
        #expect(model.nextUp.first?.id == "next-1")
    }

    private func makeClient() -> JellyfinClient {
        ServerSyncFixture.reset()
        StubURLProtocol.register(host: "jellyfin.test", handler: ServerSyncFixture.respond)
        return StubURLProtocol.makeJellyfinClient(host: "jellyfin.test", deviceId: "server-sync-tests")
    }
}

/// Fixture state for `ServerSyncTests`. Tests mutate `revision`/`isFailing`
/// after `makeClient()` already built the client, so the registered
/// `StubURLProtocol` handler reads this live rather than a fixed capture.
private enum ServerSyncFixture {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var revision = 1
    private nonisolated(unsafe) static var isFailing = false

    static func reset() {
        lock.lock()
        revision = 1
        isFailing = false
        lock.unlock()
    }

    static func setRevision(_ value: Int) {
        lock.lock()
        revision = value
        lock.unlock()
    }

    static func setFailing(_ value: Bool) {
        lock.lock()
        isFailing = value
        lock.unlock()
    }

    static func respond(to request: URLRequest) throws -> (Int, [String: String], Data) {
        guard let url = request.url else { throw URLError(.badServerResponse) }

        lock.lock()
        let currentRevision = revision
        let shouldFail = isFailing
        lock.unlock()

        if shouldFail || (currentRevision == 0 && url.path == "/Shows/NextUp") {
            throw URLError(.notConnectedToInternet)
        }

        return (200, ["Content-Type": "application/json"], Data(body(for: url, revision: currentRevision).utf8))
    }

    private static func body(for url: URL, revision: Int) -> String {
        switch url.path {
        case "/Users/user/Views":
            return page(item(
                id: "library",
                name: "Movies",
                type: "CollectionFolder",
                extra: #", "CollectionType": "movies""#
            ))
        case "/Users/user/Items/Resume":
            if revision == 0 { return page(nil) }
            return page(item(id: "resume-\(revision)", name: "Resume", type: "Movie"))
        case "/Shows/NextUp":
            return page(item(id: "next-\(revision)", name: "Next", type: "Episode"))
        case "/Users/user/Items/Latest":
            return "[\(item(id: "latest-\(revision)", name: "Latest", type: "Movie"))]"
        case "/Genres", "/HomeScreen/Sections":
            return #"{"Items":[]}"#
        case "/Users/user/Items":
            if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "Filters" })?.value == "IsFavorite" {
                return page(item(
                    id: "favorite-\(revision)",
                    name: "Favorite",
                    type: "Movie"
                ))
            }
            return page(nil)
        default:
            return page(nil)
        }
    }

    private static func page(_ item: String?) -> String {
        "{\"Items\":[\(item ?? "")],\"TotalRecordCount\":\(item == nil ? 0 : 1)}"
    }

    private static func item(
        id: String,
        name: String,
        type: String,
        extra: String = ""
    ) -> String {
        "{\"Id\":\"\(id)\",\"Name\":\"\(name)\",\"Type\":\"\(type)\"\(extra)}"
    }
}
