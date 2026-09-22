import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr API integration", .serialized)
struct SeerrClientTests {
    @Test func permissionFlagsRespectAdminAndGranularRequestAccess() {
        let movieUser = user(permissions: SeerrPermission.requestMovie.rawValue)
        #expect(movieUser.canRequest(.movie))
        #expect(!movieUser.canRequest(.tv))
        #expect(!movieUser.canManageRequests)

        let manager = user(permissions: SeerrPermission.manageRequests.rawValue)
        #expect(manager.canManageRequests)
        #expect(manager.canViewAllRequests)

        let admin = user(permissions: SeerrPermission.admin.rawValue)
        #expect(admin.canManageRequests)
        #expect(admin.canRequest(.movie))
        #expect(admin.canRequest(.tv))
    }

    @Test func candidateURLsPreferHTTPSAndStripAPISuffix() {
        let inferred = SeerrClient.candidateURLs(for: "seerr.example.com")
        #expect(inferred.first?.absoluteString == "https://seerr.example.com")
        #expect(inferred.contains(URL(string: "http://seerr.example.com:5055")!))

        let explicit = SeerrClient.candidateURLs(for: "https://seerr.example.com/api/v1/")
        #expect(explicit == [URL(string: "https://seerr.example.com")!])
    }

    @Test func quickConnectCapturesCookieAndScopesFollowingRequests() async throws {
        let client = makeClient()
        client.configure(serverURL: URL(string: "https://seerr.test/base")!)

        let signedIn = try await client.authenticateQuickConnect(secret: "secret-1")
        #expect(signedIn.id == 7)
        #expect(client.sessionCookie == "s%3Asession.signature")

        let current = try await client.currentUser()
        #expect(current.name == "Alex")

        let requests = SeerrMockURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests[0].path == "/base/api/v1/auth/jellyfin/quickconnect/authenticate")
        #expect(requests[0].body?.contains(#""secret":"secret-1""#) == true)
        #expect(requests[1].cookie == "connect.sid=s%3Asession.signature")
        #expect(requests.allSatisfy { !$0.handlesCookies })
        // Without an active cookie, never fall back to the process cookie jar.
        client.clear()
        client.configure(serverURL: URL(string: "https://seerr.test/base")!)
        _ = try await client.status()
        #expect(SeerrMockURLProtocol.requests.last?.cookie == nil)
    }

    @Test func serverSetupValidatesBeforeProbingAndPersistsTheSuccessfulProxyRoot() async throws {
        let client = makeClient()
        let suite = "SeerrAddressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let localData = AccountLocalData(defaults: defaults, credentials: MemoryAccountCredentials())
        let store = SeerrSessionStore(client: client, defaults: defaults, localData: localData)
        let account = StoredAccount(serverURL: URL(string: "https://jellyfin.test")!, serverName: "Fixture", userId: "user", userName: "Viewer")
        store.select(account)
        defer { store.select(nil) }
        do {
            try await store.connect(to: "https://user:secret@seerr.test")
            Issue.record("Invalid input must not start discovery")
        } catch ServerAddress.Failure.invalid {}
        #expect(SeerrMockURLProtocol.requests.isEmpty)
        #expect(!store.isLoading)
        #expect(store.configuredURL == nil)
        // The proxy's own path ends in /api/v1; strip the user's suffix once.
        try await store.connect(to: "seerr.test/proxy%2Fname/api/v1/api/v1/")
        let root = "http://seerr.test:5055/proxy%2Fname/api/v1"
        #expect(store.configuredURL?.absoluteString == root)
        #expect(defaults.string(forKey: AccountLocalData.seerrServerKey(account)) == root)
        #expect(store.isConfigured)
        let copy = client.sessionSnapshot()
        #expect(copy.serverURL?.absoluteString == root)
        _ = try await copy.status()
        await store.activate(for: account)
        #expect(store.configuredURL?.absoluteString == root)
        #expect(store.client.serverURL?.absoluteString == root)
        let requests = SeerrMockURLProtocol.requests
        #expect(requests.contains { $0.url.absoluteString == root + "/api/v1/settings/public" })
        #expect(requests.contains { $0.url.absoluteString == root + "/api/v1/status" })
        #expect(requests.allSatisfy { $0.cookie == nil })
    }

    @Test func discoveryDecodesAvailabilityAndRequestState() async throws {
        let client = makeClient()
        client.configure(serverURL: URL(string: "https://seerr.test")!)
        client.setSessionCookie("session")

        let page = try await client.trending(mediaType: .movie)
        let item = try #require(page.results.first)
        #expect(item.displayTitle == "Arrival")
        #expect(item.year == "2016")
        #expect(item.mediaInfo?.availability == .processing)
        #expect(item.mediaInfo?.jellyfinMediaId == "jellyfin-arrival")
        #expect(item.mediaInfo?.requests?.first?.requestStatus == .approved)
        #expect(SeerrMockURLProtocol.requests.first?.query?.contains("mediaType=movie") == true)
    }

    /// TMDB multi-search also returns `collection` and may add more types;
    /// an unknown one costs that result its type, not the whole page.
    @Test func searchSurvivesMediaTypesThisBuildDoesNotKnow() throws {
        let payload = #"""
        {"page":1,"totalPages":1,"totalResults":4,"results":[
          {"id":1,"mediaType":"movie","title":"Arrival"},
          {"id":2,"mediaType":"collection","title":"Harry Potter Collection"},
          {"id":3,"mediaType":"holotape","title":"From A Later Jellyseerr"},
          {"id":4,"mediaType":"tv","name":"Severance"}
        ]}
        """#
        let page = try JSONDecoder().decode(SeerrDiscoverPage.self, from: Data(payload.utf8))

        #expect(page.results.count == 4)
        #expect(page.results.map(\.displayTitle) == [
            "Arrival", "Harry Potter Collection", "From A Later Jellyseerr", "Severance",
        ])
        // Unknown types land typeless, which the search filters already drop.
        #expect(page.results.map(\.mediaType) == [.movie, nil, nil, .tv])
        #expect(page.results.filter { $0.mediaType == .movie || $0.mediaType == .tv }.count == 2)
    }

    @Test func nestedMediaInfoToleratesAnUnknownMediaType() throws {
        let payload = #"""
        {"id":5,"mediaType":"movie","title":"Arrival",
         "mediaInfo":{"id":8,"tmdbId":329865,"mediaType":"collection","status":5}}
        """#
        let result = try JSONDecoder().decode(SeerrDiscoverResult.self, from: Data(payload.utf8))

        #expect(result.mediaType == .movie)
        #expect(result.mediaInfo?.mediaType == nil)
        #expect(result.mediaInfo?.availability == .available)
        #expect(result.mediaInfo?.tmdbId == 329865)
    }

    /// `resolvedMediaType` falls back to the media's own type, then the tvdb id.
    @Test func requestWithUnknownTypeStillResolvesAndDecodes() throws {
        let payload = #"""
        {"id":41,"status":2,"type":"holotape",
         "media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"holotape","status":3}}
        """#
        let request = try JSONDecoder().decode(SeerrMediaRequest.self, from: Data(payload.utf8))

        #expect(request.type == nil)
        #expect(request.media?.mediaType == nil)
        #expect(request.resolvedMediaType == .tv)
        #expect(request.tmdbID == 60625)
    }

    @Test func televisionRequestAndModerationUseDocumentedContracts() async throws {
        let client = makeClient()
        client.configure(serverURL: URL(string: "https://seerr.test")!)
        client.setSessionCookie("session")

        let created = try await client.createRequest(SeerrCreateRequest(
            mediaType: .tv,
            mediaId: 60625,
            seasons: [1, 2],
            is4k: false
        ))
        #expect(created.id == 41)
        #expect(created.resolvedMediaType == .tv)

        let approved = try await client.setRequestStatus(id: 41, approved: true)
        #expect(approved.requestStatus == .approved)

        let requests = SeerrMockURLProtocol.requests
        #expect(requests[0].path == "/api/v1/request")
        #expect(requests[0].body?.contains(#""mediaType":"tv""#) == true)
        #expect(requests[0].body?.contains(#""seasons":[1,2]"#) == true)
        #expect(requests[1].path == "/api/v1/request/41/approve")
    }

    @Test func requestListingDecodesPaginationAndScopesToCurrentUser() async throws {
        let client = makeClient()
        client.configure(serverURL: URL(string: "https://seerr.test")!)
        client.setSessionCookie("session")

        let page = try await client.requests(
            take: 20,
            skip: 0,
            filter: .pending,
            requestedBy: 7
        )

        #expect(page.pageInfo.page == 1)
        #expect(page.pageInfo.pages == 1)
        #expect(page.results.first?.id == 41)
        #expect(page.results.first?.requestStatus == .pending)

        let query = SeerrMockURLProtocol.requests.first?.query ?? ""
        #expect(query.contains("take=20"))
        #expect(query.contains("skip=0"))
        #expect(query.contains("filter=pending"))
        #expect(query.contains("requestedBy=7"))
    }

    @Test func requestDeadlineEndsAStalledSearch() async throws {
        let client = makeClient(requestTimeout: 0.05)
        client.configure(serverURL: URL(string: "https://seerr.test")!)
        client.setSessionCookie("session")

        do {
            _ = try await client.search(query: "alien")
            Issue.record("A stalled Seerr search did not reach its absolute deadline")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
    }

    @Test func anAuthProxyAnsweringWithAWebPageIsNotBlamedOnSeerr() async throws {
        let client = makeClient()
        client.configure(serverURL: URL(string: "https://seerr.test/access")!)

        await #expect(throws: SeerrError.webPageResponse) {
            _ = try await client.status()
        }
    }

    private func makeClient(requestTimeout: TimeInterval = 20) -> SeerrClient {
        SeerrMockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrMockURLProtocol.self]
        return SeerrClient(
            session: URLSession(configuration: configuration),
            requestTimeout: requestTimeout
        )
    }

    private func user(permissions: Int) -> SeerrUser {
        SeerrUser(
            id: 1,
            email: nil,
            username: "user",
            displayName: nil,
            jellyfinUsername: nil,
            avatar: nil,
            permissions: permissions
        )
    }
}

private nonisolated struct RecordedSeerrRequest: Sendable {
    let url: URL
    let method: String
    let path: String
    let query: String?
    let cookie: String?
    let body: String?
    let handlesCookies: Bool
}

private nonisolated final class SeerrMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [RecordedSeerrRequest] = []

    static var requests: [RecordedSeerrRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock()
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "seerr.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = bodyString(from: request)
        Self.lock.lock()
        Self.recorded.append(RecordedSeerrRequest(
            url: url,
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: url.query,
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            body: body,
            handlesCookies: request.httpShouldHandleCookies
        ))
        Self.lock.unlock()

        if url.path(percentEncoded: true).hasPrefix("/proxy%2Fname/"), url.port != 5055 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        // Never finishes: the client needs an absolute deadline, not just
        // URLSession's inactivity timer.
        if url.path == "/api/v1/search" {
            return
        }

        let result = response(for: url)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func bodyString(from request: URLRequest) -> String? {
        if let body = request.httpBody {
            return String(data: body, encoding: .utf8)
        }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(data: data, encoding: .utf8)
    }

    private func response(for url: URL) -> (status: Int, headers: [String: String], body: String) {
        if url.port == 5055, url.path(percentEncoded: true).hasPrefix("/proxy%2Fname/api/v1/") {
            return (200, ["Content-Type": "application/json"], url.path.hasSuffix("/status")
                    ? #"{"version":"test"}"# : #"{"initialized":true,"mediaServerType":2}"#)
        }
        switch (request.httpMethod ?? "GET", url.path) {
        case ("POST", "/base/api/v1/auth/jellyfin/quickconnect/authenticate"):
            return (200, [
                "Content-Type": "application/json",
                "Set-Cookie": "connect.sid=s%3Asession.signature; Path=/; HttpOnly; Secure",
            ], userJSON)
        case ("GET", "/base/api/v1/auth/me"):
            return (200, ["Content-Type": "application/json"], userJSON)
        case ("GET", "/base/api/v1/status"):
            return (200, ["Content-Type": "application/json"], #"{"version":"test"}"#)
        // An auth proxy in front of Seerr: the followed redirect gives 200 and HTML.
        case ("GET", "/access/api/v1/status"):
            return (200, ["Content-Type": "text/html; charset=utf-8"], "<html><body>Sign in</body></html>")
        case ("GET", "/api/v1/discover/trending"):
            return (200, ["Content-Type": "application/json"], #"{"page":1,"totalPages":1,"totalResults":1,"results":[{"id":329865,"mediaType":"movie","title":"Arrival","releaseDate":"2016-11-11","mediaInfo":{"id":8,"tmdbId":329865,"status":3,"jellyfinMediaId":"jellyfin-arrival","requests":[{"id":9,"status":2}]}}]}"#)
        case ("GET", "/api/v1/request"):
            return (200, ["Content-Type": "application/json"], #"{"pageInfo":{"page":1,"pages":1,"pageSize":20,"results":1},"results":[{"id":41,"status":1,"type":"tv","media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"tv","status":2},"requestedBy":{"id":7,"username":"alex","permissions":32},"seasons":[{"id":1,"seasonNumber":1}]}]}"#)
        case ("POST", "/api/v1/request"):
            return (201, ["Content-Type": "application/json"], #"{"id":41,"status":1,"type":"tv","media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"tv","status":2},"seasons":[{"id":1,"seasonNumber":1}]}"#)
        case ("POST", "/api/v1/request/41/approve"):
            return (200, ["Content-Type": "application/json"], #"{"id":41,"status":2,"type":"tv","media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"tv","status":3}}"#)
        default:
            return (404, ["Content-Type": "application/json"], #"{"message":"Not found"}"#)
        }
    }

    private var userJSON: String {
        #"{"id":7,"username":"alex","displayName":"Alex","permissions":32}"#
    }
}
