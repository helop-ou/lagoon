import Foundation
import Testing
@testable import Lagoon

@Suite("Profile activity", .serialized)
@MainActor
struct ProfileActivityTests {
    @Test func peeksWithTheProfilesOwnTokenNotTheActiveSession() async throws {
        let client = makeClient()
        ProfileActivityURLProtocol.respond(status: 200, body: #"""
        {"Items":[{"Id":"episode","Type":"Episode","Name":"Next of Kin","SeriesName":"9-1-1"}]}
        """#)

        let item = await client.peekResume(
            serverURL: URL(string: "https://profile-activity.test/jellyfin")!,
            userId: "partner",
            token: "partner-token"
        )

        #expect(item?.railTitle == "9-1-1")
        let request = try #require(ProfileActivityURLProtocol.requests.first)
        #expect(request.url?.path == "/jellyfin/Users/partner/Items/Resume")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "Limit", value: "1")))
        let authorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(authorization.contains(#"Token="partner-token""#))
        #expect(!authorization.contains("active-token"))
    }

    @Test func aRejectedTokenShowsNothingAndLeavesTheSessionAlone() async {
        let client = makeClient()
        var expired = false
        client.onSessionExpired = { _ in expired = true }
        ProfileActivityURLProtocol.respond(status: 401, body: "{}")

        let item = await client.peekResume(
            serverURL: URL(string: "https://profile-activity.test")!,
            userId: "partner",
            token: "revoked"
        )

        #expect(item == nil)
        #expect(!expired)
    }

    private func makeClient() -> JellyfinClient {
        ProfileActivityURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProfileActivityURLProtocol.self]
        let client = JellyfinClient(deviceId: "device", sessionConfiguration: configuration)
        client.configure(serverURL: URL(string: "https://profile-activity.test")!)
        client.activateSession(token: "active-token", userId: "me")
        return client
    }
}

private nonisolated final class ProfileActivityURLProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var requests: [URLRequest] = []
        var status = 200
        var body = #"{"Items":[]}"#
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    static var requests: [URLRequest] { lock.withLock { state.requests } }
    static func reset() { lock.withLock { state = State() } }
    static func respond(status: Int, body: String) {
        lock.withLock {
            state.status = status
            state.body = body
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "profile-activity.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, body) = Self.lock.withLock {
            Self.state.requests.append(request)
            return (Self.state.status, Self.state.body)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
