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
        #expect(current.name == "Jaagop")

        let requests = SeerrMockURLProtocol.requests
        #expect(requests.count == 2)
        #expect(requests[0].path == "/base/api/v1/auth/jellyfin/quickconnect/authenticate")
        #expect(requests[0].body?.contains(#""secret":"secret-1""#) == true)
        #expect(requests[1].cookie == "connect.sid=s%3Asession.signature")
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
        #expect(item.mediaInfo?.requests?.first?.requestStatus == .approved)
        #expect(SeerrMockURLProtocol.requests.first?.query?.contains("mediaType=movie") == true)
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

    private func makeClient() -> SeerrClient {
        SeerrMockURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrMockURLProtocol.self]
        return SeerrClient(session: URLSession(configuration: configuration))
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
    let method: String
    let path: String
    let query: String?
    let cookie: String?
    let body: String?
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
            method: request.httpMethod ?? "GET",
            path: url.path,
            query: url.query,
            cookie: request.value(forHTTPHeaderField: "Cookie"),
            body: body
        ))
        Self.lock.unlock()

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
        switch (request.httpMethod ?? "GET", url.path) {
        case ("POST", "/base/api/v1/auth/jellyfin/quickconnect/authenticate"):
            return (200, [
                "Content-Type": "application/json",
                "Set-Cookie": "connect.sid=s%3Asession.signature; Path=/; HttpOnly; Secure",
            ], userJSON)
        case ("GET", "/base/api/v1/auth/me"):
            return (200, ["Content-Type": "application/json"], userJSON)
        case ("GET", "/api/v1/discover/trending"):
            return (200, ["Content-Type": "application/json"], #"{"page":1,"totalPages":1,"totalResults":1,"results":[{"id":329865,"mediaType":"movie","title":"Arrival","releaseDate":"2016-11-11","mediaInfo":{"id":8,"tmdbId":329865,"status":3,"requests":[{"id":9,"status":2}]}}]}"#)
        case ("GET", "/api/v1/request"):
            return (200, ["Content-Type": "application/json"], #"{"pageInfo":{"page":1,"pages":1,"pageSize":20,"results":1},"results":[{"id":41,"status":1,"type":"tv","media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"tv","status":2},"requestedBy":{"id":7,"username":"jaagop","permissions":32},"seasons":[{"id":1,"seasonNumber":1}]}]}"#)
        case ("POST", "/api/v1/request"):
            return (201, ["Content-Type": "application/json"], #"{"id":41,"status":1,"type":"tv","media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"tv","status":2},"seasons":[{"id":1,"seasonNumber":1}]}"#)
        case ("POST", "/api/v1/request/41/approve"):
            return (200, ["Content-Type": "application/json"], #"{"id":41,"status":2,"type":"tv","media":{"id":8,"tmdbId":60625,"tvdbId":275274,"mediaType":"tv","status":3}}"#)
        default:
            return (404, ["Content-Type": "application/json"], #"{"message":"Not found"}"#)
        }
    }

    private var userJSON: String {
        #"{"id":7,"username":"jaagop","displayName":"Jaagop","permissions":32}"#
    }
}
