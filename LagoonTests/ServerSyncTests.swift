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

        ServerSyncURLProtocol.setRevision(1)
        await model.load(client: client, accountID: "account")
        #expect(model.resume.first?.id == "resume-1")
        #expect(model.nextUp.first?.id == "next-1")
        #expect(model.favorites.first?.id == "favorite-1")
        #expect(model.latestRails.first?.items.first?.id == "latest-1")

        ServerSyncURLProtocol.setRevision(2)
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
        ServerSyncURLProtocol.setFailing(true)
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

    private func makeClient() -> JellyfinClient {
        ServerSyncURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerSyncURLProtocol.self]
        let client = JellyfinClient(
            deviceId: "server-sync-tests",
            sessionConfiguration: configuration
        )
        client.configure(serverURL: URL(string: "https://jellyfin.test")!)
        client.activateSession(token: "token", userId: "user")
        return client
    }
}

private nonisolated final class ServerSyncURLProtocol: URLProtocol, @unchecked Sendable {
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

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "jellyfin.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        Self.lock.lock()
        let currentRevision = Self.revision
        let shouldFail = Self.isFailing
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        let body = Self.body(for: url, revision: currentRevision)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

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
