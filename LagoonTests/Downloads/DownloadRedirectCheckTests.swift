import Foundation
import LagoonEngine
import Testing
@testable import Lagoon

/// A background download cannot drop a proxy's headers on a redirect, so the
/// check before it must find where the URL leads.
@Suite("Download redirect check", .serialized)
struct DownloadRedirectCheckTests {
    private let url = URL(string: "https://jf.example.com/Items/1/Download?api_key=t")!

    @Test func onlyARedirectOffTheHostOrOffHTTPSLeavesTheServer() {
        #expect(DownloadRedirectCheck.step(from: url, status: 200, location: nil) == .done(.staysOnServer))
        // A proxy or server error is not a redirect; the transfer reports it.
        #expect(DownloadRedirectCheck.step(from: url, status: 403, location: nil) == .done(.staysOnServer))
        #expect(DownloadRedirectCheck.step(from: url, status: 302, location: "https://team.cloudflareaccess.com/login")
            == .done(.leavesServer))
        #expect(DownloadRedirectCheck.step(from: url, status: 301, location: "http://jf.example.com/Items/1/Download")
            == .done(.leavesServer))
        #expect(DownloadRedirectCheck.step(from: url, status: 307, location: nil) == .done(.leavesServer))
        #expect(DownloadRedirectCheck.step(from: url, status: 308, location: "/jellyfin/Items/1/Download")
            == .follow(URL(string: "/jellyfin/Items/1/Download", relativeTo: url)!.absoluteURL))
    }

    @Test func onlyATransferCarryingProxyHeadersIsChecked() {
        func authorization(_ headers: [String: String]) -> MediaRequestAuthorization {
            MediaRequestAuthorization(
                origin: URL(string: "https://jf.example.com")!, headerName: "Authorization", headerValue: "token",
                queryNames: ["api_key"], additionalHeaders: headers
            )
        }
        #expect(!DownloadRedirectCheck.isNeeded(for: authorization([:])))
        #expect(DownloadRedirectCheck.isNeeded(for: authorization(["CF-Access-Client-Secret": "secret"])))
    }

    @Test func theCheckFollowsTheServerAndStopsAtAHopThatLeavesIt() async {
        let session = RedirectFixtureProtocol.session()
        var request = URLRequest(url: url)
        request.setValue("secret", forHTTPHeaderField: "CF-Access-Client-Secret")

        RedirectFixtureProtocol.set(["/Items/1/Download": (302, "/jellyfin/Items/1/Download"), "/jellyfin/Items/1/Download": (200, nil)])
        #expect(await DownloadRedirectCheck.check(request, session: session) == .staysOnServer)

        RedirectFixtureProtocol.set(["/Items/1/Download": (302, "https://team.cloudflareaccess.com/login")])
        #expect(await DownloadRedirectCheck.check(request, session: session) == .leavesServer)
        // Nothing was sent to the login host: the redirect was refused.
        #expect(RedirectFixtureProtocol.requests.allSatisfy { $0.url?.host() == "jf.example.com" })
        #expect(RedirectFixtureProtocol.requests.allSatisfy { $0.httpMethod == "HEAD" })

        RedirectFixtureProtocol.set(["/Items/1/Download": (302, "/Items/1/Download")])
        #expect(await DownloadRedirectCheck.check(request, session: session) == .leavesServer)

        RedirectFixtureProtocol.set([:])
        #expect(await DownloadRedirectCheck.check(request, session: session) == .unreachable)
    }
}

/// Answers by path; an unknown path fails as if offline. A redirect comes
/// back as the response itself, which is what refusing it yields from a real
/// server; a URLProtocol that reports `wasRedirectedTo` never completes once
/// the redirect is refused.
private nonisolated final class RedirectFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var routes: [String: (Int, String?)] = [:]
    private nonisolated(unsafe) static var recorded: [URLRequest] = []

    static var requests: [URLRequest] { lock.withLock { recorded } }

    static func set(_ value: [String: (Int, String?)]) {
        lock.withLock { routes = value; recorded = [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let route = Self.lock.withLock { () -> (Int, String?)? in
            Self.recorded.append(request)
            return Self.routes[url.path()]
        }
        guard let (status, location) = route else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let headers = location.map { ["Location": $0] } ?? [:]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
