import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr live detail refresh")
struct SeerrLiveRefreshTests {
    @Test func approvalAndTransferCadencesAreDeliberatelyDifferent() {
        #expect(SeerrLiveRefreshCadence.waitingForApproval.interval() == .seconds(30))
        #expect(SeerrLiveRefreshCadence.transferring.interval() == .seconds(10))
    }

    @Test func debugCadenceCanRunWithoutAProductionLengthWait() {
        let suite = "SeerrLiveRefreshTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(0.05, forKey: "debug.seerrLiveRefreshIntervalSeconds")
        #expect(
            SeerrLiveRefreshCadence.transferring.interval(defaults: defaults)
                == .seconds(0.05)
        )
    }

    @Test func requestDetailsPollOnlyWhileTheirStateCanStillChange() throws {
        #expect(SeerrLiveRefreshCadence.request(try request(status: 1, mediaStatus: 2)) == .waitingForApproval)
        #expect(SeerrLiveRefreshCadence.request(try request(status: 2, mediaStatus: 3)) == .transferring)
        #expect(SeerrLiveRefreshCadence.request(try request(status: 2, mediaStatus: 4)) == .transferring)

        for settled in [
            try request(status: 3, mediaStatus: 1),
            try request(status: 4, mediaStatus: 3),
            try request(status: 5, mediaStatus: 5),
        ] {
            #expect(SeerrLiveRefreshCadence.request(settled) == nil)
        }
    }

    @Test func mediaDetailsFollowTheFastestUnsettledSignal() throws {
        #expect(SeerrLiveRefreshCadence.mediaDetails(try details(mediaStatus: 2)) == .waitingForApproval)
        #expect(SeerrLiveRefreshCadence.mediaDetails(try details(mediaStatus: 3)) == .transferring)
        #expect(
            SeerrLiveRefreshCadence.mediaDetails(
                try details(mediaStatus: 4, requestStatus: 2)
            ) == .transferring
        )
        #expect(
            SeerrLiveRefreshCadence.mediaDetails(
                try details(mediaStatus: 1, requestStatus: 1)
            ) == .waitingForApproval
        )
    }

    /// Jellyseerr can briefly leave old queue rows attached after import.
    /// Availability is authoritative, so that stale row must not poll forever.
    @Test func terminalMediaStopsEvenWithAStaleQueueRow() throws {
        let loaded = try JSONDecoder().decode(
            SeerrMediaDetails.self,
            from: Data(
                #"{"id":603,"mediaInfo":{"status":5,"downloadStatus":[{"downloadId":"old","size":100,"sizeLeft":0}]}}"#.utf8
            )
        )
        #expect(SeerrLiveRefreshCadence.mediaDetails(loaded) == nil)
    }

    @Test @MainActor func refreshesAreSequentialAndStopWhenThePageSettles() async {
        var sleepCount = 0
        var refreshCount = 0
        var inFlight = 0
        var maximumInFlight = 0
        var isUnsettled = true

        await SeerrLiveRefreshLoop.run(
            interval: .seconds(10),
            sleep: { _ in sleepCount += 1 },
            shouldContinue: { isUnsettled }
        ) {
            inFlight += 1
            maximumInFlight = max(maximumInFlight, inFlight)
            await Task.yield()
            refreshCount += 1
            inFlight -= 1
            if refreshCount == 3 { isUnsettled = false }
        }

        #expect(sleepCount == 3)
        #expect(refreshCount == 3)
        #expect(maximumInFlight == 1)
    }

    @Test @MainActor func cancellingTheStructuredTaskStopsBeforeARefresh() async {
        var refreshCount = 0
        let task = Task { @MainActor in
            await SeerrLiveRefreshLoop.run(
                interval: .seconds(60),
                sleep: { duration in try await Task.sleep(for: duration) }
            ) {
                refreshCount += 1
            }
        }

        await Task.yield()
        task.cancel()
        await task.value

        #expect(refreshCount == 0)
    }

    private func request(status: Int, mediaStatus: Int) throws -> SeerrMediaRequest {
        try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(
                #"{"id":7,"status":\#(status),"type":"movie","media":{"id":1,"tmdbId":603,"status":\#(mediaStatus)}}"#.utf8
            )
        )
    }

    private func details(mediaStatus: Int, requestStatus: Int? = nil) throws -> SeerrMediaDetails {
        let requests = requestStatus.map {
            #", "requests":[{"id":7,"status":\#($0)}]"#
        } ?? ""
        return try JSONDecoder().decode(
            SeerrMediaDetails.self,
            from: Data(
                #"{"id":603,"mediaInfo":{"status":\#(mediaStatus)\#(requests)}}"#.utf8
            )
        )
    }
}

/// What a poll actually does over the wire, and what it does to the page when
/// the server is briefly unreachable. Serialized because the stub protocol
/// holds its script and its recording in shared state.
@Suite("Seerr request detail polling", .serialized)
@MainActor
struct SeerrRequestDetailRefreshTests {
    /// The whole point of HEL-136 is observing state the server has just
    /// changed, so a cached body is the one answer that must never come back.
    @Test func everySeerrCallBypassesTheHTTPCache() async throws {
        let clients = makeClients(request: Fixtures.downloadingRequest)
        _ = try await clients.seerr.request(id: 41)

        let recorded = try #require(SeerrDetailURLProtocol.records.first)
        #expect(recorded.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    /// Title, artwork and genres cannot change while a request is watched, so
    /// a poll that re-reads TMDB is two thirds wasted traffic.
    @Test func aPollReadsOnlyTheRequestItself() async throws {
        let clients = makeClients(request: Fixtures.downloadingRequest)
        let model = SeerrRequestDetailModel(request: try decodedRequest(Fixtures.pendingRequest))

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)
        #expect(model.details?.displayTitle == "Arrival")
        #expect(model.currentRequest.downloadProgress?.percentText == "62%")
        #expect(SeerrDetailURLProtocol.paths.contains("/api/v1/movie/603"))

        SeerrDetailURLProtocol.clearRecords()
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(SeerrDetailURLProtocol.paths == ["/api/v1/request/41"])
        #expect(model.details?.displayTitle == "Arrival")
    }

    /// The one thing on the TMDB payload that is not static: the Jellyfin id
    /// arrives with the title. It is worth exactly one extra fetch, and never
    /// a fetch per cadence afterwards.
    @Test func availabilityResolvesTheJellyfinItemOnceAndThenStopsAsking() async throws {
        let clients = makeClients(request: Fixtures.downloadingRequest)
        let model = SeerrRequestDetailModel(request: try decodedRequest(Fixtures.pendingRequest))

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)
        #expect(model.jellyfinItem == nil)

        SeerrDetailURLProtocol.setRequest(Fixtures.availableRequest)
        SeerrDetailURLProtocol.setDetails(Fixtures.availableDetails)
        SeerrDetailURLProtocol.clearRecords()
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(model.jellyfinItem?.id == "jellyfin-arrival")
        #expect(SeerrDetailURLProtocol.paths == [
            "/api/v1/request/41",
            "/api/v1/movie/603",
            "/Users/user/Items/jellyfin-arrival",
        ])

        SeerrDetailURLProtocol.clearRecords()
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(SeerrDetailURLProtocol.paths == ["/api/v1/request/41"])
        #expect(model.jellyfinItem?.id == "jellyfin-arrival")
    }

    @Test func aFailedPollKeepsTheLastGoodDetail() async throws {
        let clients = makeClients(request: Fixtures.downloadingRequest)
        let model = SeerrRequestDetailModel(request: try decodedRequest(Fixtures.pendingRequest))

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)
        SeerrDetailURLProtocol.setFailing(true)
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(model.errorMessage == nil)
        #expect(model.details?.displayTitle == "Arrival")
        #expect(model.currentRequest.downloadProgress?.percentText == "62%")
    }

    /// A request whose media carries no TMDB id has no details to load, so
    /// "have we ever rendered anything" cannot be answered by asking whether
    /// `details` is nil — that read the good page as a blank one and painted
    /// the error over it on every transient failure.
    @Test func aFailedPollKeepsAPageThatNeverHadTMDBMetadata() async throws {
        let clients = makeClients(request: Fixtures.requestWithoutTMDBID)
        let model = SeerrRequestDetailModel(
            request: try decodedRequest(Fixtures.requestWithoutTMDBID)
        )

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)
        #expect(model.hasLoadedOnce)
        #expect(model.details == nil)
        #expect(model.errorMessage == nil)

        SeerrDetailURLProtocol.setFailing(true)
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)

        #expect(model.errorMessage == nil)
        #expect(model.currentRequest.requestStatus == .pending)
    }

    /// Retention is not silence: a page that has never loaded still owes the
    /// viewer the reason it is empty.
    @Test func aFailureBeforeAnyGoodSnapshotStillReachesTheViewer() async throws {
        let clients = makeClients(request: Fixtures.downloadingRequest)
        let model = SeerrRequestDetailModel(request: try decodedRequest(Fixtures.pendingRequest))
        SeerrDetailURLProtocol.setFailing(true)

        await model.load(client: clients.seerr, jellyfin: clients.jellyfin, isRefresh: true)
        #expect(!model.hasLoadedOnce)
        #expect(model.errorMessage != nil)

        model.errorMessage = nil
        await model.load(client: clients.seerr, jellyfin: clients.jellyfin)
        #expect(model.errorMessage != nil)
    }

    private func makeClients(request: String) -> (seerr: SeerrClient, jellyfin: JellyfinClient) {
        SeerrDetailURLProtocol.reset(request: request, details: Fixtures.details)
        let seerr = SeerrClient(session: URLSession(configuration: stubConfiguration()), requestTimeout: 5)
        seerr.configure(serverURL: URL(string: "https://seerr.detail.test")!)
        seerr.setSessionCookie("session")

        let jellyfin = JellyfinClient(
            deviceId: "seerr-detail-tests",
            sessionConfiguration: stubConfiguration()
        )
        jellyfin.configure(serverURL: URL(string: "https://jellyfin.detail.test")!)
        jellyfin.activateSession(token: "token", userId: "user")
        return (seerr, jellyfin)
    }

    private func stubConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrDetailURLProtocol.self]
        return configuration
    }

    private func decodedRequest(_ json: String) throws -> SeerrMediaRequest {
        try JSONDecoder().decode(SeerrMediaRequest.self, from: Data(json.utf8))
    }

    private enum Fixtures {
        static let pendingRequest =
            #"{"id":41,"status":1,"type":"movie","media":{"id":8,"tmdbId":603,"mediaType":"movie","status":2}}"#
        /// Approved, and Radarr is 62% of the way through fetching it.
        static let downloadingRequest =
            #"{"id":41,"status":2,"type":"movie","media":{"id":8,"tmdbId":603,"mediaType":"movie","status":3,"downloadStatus":[{"downloadId":"d1","title":"Arrival","status":"downloading","size":1000,"sizeLeft":380,"timeLeft":"00:12:00"}]}}"#
        static let availableRequest =
            #"{"id":41,"status":5,"type":"movie","media":{"id":8,"tmdbId":603,"mediaType":"movie","status":5}}"#
        /// Jellyseerr can hold a request whose media row has no TMDB id.
        static let requestWithoutTMDBID =
            #"{"id":41,"status":1,"type":"movie","media":{"id":8,"mediaType":"movie","status":2}}"#
        static let details =
            #"{"id":603,"title":"Arrival","overview":"A linguist meets the heptapods.","genres":[{"id":878,"name":"Science Fiction"}],"mediaInfo":{"id":8,"tmdbId":603,"status":3}}"#
        static let availableDetails =
            #"{"id":603,"title":"Arrival","overview":"A linguist meets the heptapods.","genres":[{"id":878,"name":"Science Fiction"}],"mediaInfo":{"id":8,"tmdbId":603,"status":5,"jellyfinMediaId":"jellyfin-arrival"}}"#
    }
}

private nonisolated struct RecordedDetailRequest: Sendable {
    let path: String
    let cachePolicy: URLRequest.CachePolicy
}

/// Serves one Seerr request/TMDB pair and the Jellyfin item behind it, and can
/// go dark on command so a poll fails the way a brief outage does.
private nonisolated final class SeerrDetailURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [RecordedDetailRequest] = []
    private nonisolated(unsafe) static var requestJSON = ""
    private nonisolated(unsafe) static var detailsJSON = ""
    private nonisolated(unsafe) static var itemJSON = ""
    private nonisolated(unsafe) static var isFailing = false

    static var records: [RecordedDetailRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static var paths: [String] { records.map(\.path) }

    static func reset(request: String, details: String) {
        lock.lock()
        recorded = []
        requestJSON = request
        detailsJSON = details
        itemJSON = #"{"Id":"jellyfin-arrival","Name":"Arrival","Type":"Movie"}"#
        isFailing = false
        lock.unlock()
    }

    static func clearRecords() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    static func setRequest(_ json: String) {
        lock.lock()
        requestJSON = json
        lock.unlock()
    }

    static func setDetails(_ json: String) {
        lock.lock()
        detailsJSON = json
        lock.unlock()
    }

    static func setFailing(_ value: Bool) {
        lock.lock()
        isFailing = value
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "seerr.detail.test" || request.url?.host == "jellyfin.detail.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.recorded.append(RecordedDetailRequest(
            path: url.path,
            cachePolicy: request.cachePolicy
        ))
        let shouldFail = Self.isFailing
        let body = Self.body(for: url.path)
        Self.lock.unlock()

        if shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let body, let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Called with the lock held.
    private static func body(for path: String) -> String? {
        switch path {
        case "/api/v1/request/41":
            return requestJSON
        case "/api/v1/movie/603":
            return detailsJSON
        // Best-effort metadata the detail asks for once (HEL-118).
        case "/api/v1/service/radarr":
            return "[]"
        case "/Users/user/Items/jellyfin-arrival":
            return itemJSON
        default:
            return nil
        }
    }
}
