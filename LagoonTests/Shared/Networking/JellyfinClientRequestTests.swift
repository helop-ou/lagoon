import Foundation
import Testing
#if canImport(UIKit)
import UIKit
#endif
@testable import Lagoon

/// What every Jellyfin request carries: the documented `Authorization`
/// shape, a cache bypass, the server's proxy headers, and a redirect guard
/// on every session that could follow one off the host.
@Suite("Jellyfin client requests", .serialized)
@MainActor
struct JellyfinClientRequestTests {
    static let host = "client-requests.test"

    private static let proxyHeaders = [
        CustomHTTPHeader(name: "CF-Access-Client-Id", value: "id.access"),
        CustomHTTPHeader(name: "CF-Access-Client-Secret", value: "proxy-secret"),
    ]

    private static var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #else
        UIDevice.current.model
        #endif
    }

    private func makeClient(
        headerStore: ServerHeaderStore = ServerHeaderStore(credentials: MemoryAccountCredentials()),
        diagnostics: DiagnosticsHub = DiagnosticsHub(reportingEnabled: { false }),
        status: Int = 200
    ) -> JellyfinClient {
        StubURLProtocol.register(host: Self.host) { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/Items/Resume") || path.hasSuffix("/Items") {
                return (status, [:], Data(#"{"Items":[],"TotalRecordCount":0}"#.utf8))
            }
            if path.hasSuffix("/AuthenticateByName") {
                return (status, [:], Data(#"{"AccessToken":"t","User":{"Id":"u","Name":"N"}}"#.utf8))
            }
            return (status, [:], Data("[]".utf8))
        }
        let client = JellyfinClient(
            deviceId: "request-tests",
            sessionConfiguration: StubURLProtocol.configuration(),
            headerStore: headerStore,
            diagnostics: diagnostics
        )
        client.configure(serverURL: URL(string: "https://\(Self.host)")!)
        client.activateSession(token: "tok", userId: "user")
        return client
    }

    private func lastRequest(_ suffix: String) throws -> URLRequest {
        try #require(StubURLProtocol.requests(host: Self.host).last { $0.url?.path.hasSuffix(suffix) == true })
    }

    // MARK: - Authorization

    /// docs/jellyfin-api.md, "Auth".
    @Test func aSignedInRequestCarriesTheDocumentedAuthorization() async throws {
        let client = makeClient()
        _ = try await client.getData("Sessions/Capabilities")
        let expected = #"MediaBrowser Client="Lagoon", Device="\#(Self.deviceName)", DeviceId="request-tests", Version="\#(client.appVersion)", Token="tok""#
        #expect(try lastRequest("/Sessions/Capabilities").value(forHTTPHeaderField: "Authorization") == expected)
        #expect(client.authorizationHeader == expected)
    }

    /// Signing in sends the identity without a token, even over a session.
    @Test func signingInCarriesNoToken() async throws {
        let client = makeClient()
        _ = try? await client.authenticateByName(username: "demo", password: "")
        let expected = #"MediaBrowser Client="Lagoon", Device="\#(Self.deviceName)", DeviceId="request-tests", Version="\#(client.appVersion)""#
        #expect(try lastRequest("/Users/AuthenticateByName").value(forHTTPHeaderField: "Authorization") == expected)
    }

    // MARK: - Cache

    /// A cached answer holds resume points and played flags from before the
    /// last report, and SwiftUI drops a write that compares equal.
    @Test func apiCallsBypassTheURLCache() async throws {
        let client = makeClient()
        #expect(client.session.configuration.urlCache == nil)
        _ = try await client.getData("Sessions/Capabilities")
        #expect(try lastRequest("/Sessions/Capabilities").cachePolicy == .reloadIgnoringLocalCacheData)
        _ = await client.peekResume(serverURL: URL(string: "https://\(Self.host)")!, userId: "other", token: "other-token")
        let peek = try lastRequest("/Items/Resume")
        #expect(peek.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(peek.value(forHTTPHeaderField: "Authorization")?.hasSuffix(#", Token="other-token""#) == true)
    }

    // MARK: - Proxy headers

    @Test func everyTransportCarriesTheServersProxyHeaders() async throws {
        let store = ServerHeaderStore(credentials: MemoryAccountCredentials())
        try store.setHeaders(Self.proxyHeaders, forHost: Self.host)
        let client = makeClient(headerStore: store)

        _ = try await client.getData("Sessions/Capabilities")
        let request = try lastRequest("/Sessions/Capabilities")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "id.access")
        #expect(request.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")

        _ = await client.peekResume(serverURL: URL(string: "https://\(Self.host)")!, userId: "other", token: "other-token")
        #expect(try lastRequest("/Items/Resume").value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")

        // The engine's byte source, which never sees a URLRequest of ours.
        #expect(client.mediaRequestAuthorization()?.additionalHeaders == [
            "CF-Access-Client-Id": "id.access",
            "CF-Access-Client-Secret": "proxy-secret",
        ])

        let handshake = try #require(ServerSocket(client: client).handshakeRequest)
        #expect(handshake.url?.scheme == "wss")
        #expect(handshake.value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")

        // A copy for work that outlives an account change keeps them too.
        _ = try await client.sessionSnapshot().getData("Sessions/Capabilities")
        #expect(try lastRequest("/Sessions/Capabilities").value(forHTTPHeaderField: "CF-Access-Client-Secret") == "proxy-secret")
    }

    // MARK: - Redirects

    @Test func everyAppSessionGuardsRedirects() {
        let client = makeClient()
        #expect(client.session.delegate is ServerHeaderRedirectGuard)
        #expect(ServerSocket(client: client).session.delegate is ServerHeaderRedirectGuard)
        #expect(ServerSocket(client: client).session.configuration.urlCache == nil)
        #expect(JellyfinClient.reachabilitySession.delegate is ServerHeaderRedirectGuard)
        let uncached = UncachedSession.make(waitsForConnectivity: false)
        #expect(uncached.delegate is ServerHeaderRedirectGuard)
        #expect(uncached.configuration.urlCache == nil)
        #expect(uncached.configuration.httpCookieStorage == nil)
    }

    // MARK: - Incidents

    /// A probe's failure is an answer, so it never becomes an incident; an
    /// ordinary request failing the same way does.
    @Test func aFailedProbeIsNeverAnIncident() async throws {
        let sink = CapturingSink()
        let client = makeClient(diagnostics: DiagnosticsHub(sink: sink, reportingEnabled: { true }), status: 500)
        #expect(await client.isSyncPlayAvailable() == false)
        #expect(sink.codes.isEmpty)
        _ = try? await client.syncPlayGroups()
        #expect(sink.codes == [.apiRequestFailed])
    }

    nonisolated final class CapturingSink: DiagnosticSink, @unchecked Sendable {
        private let lock = NSLock()
        private var incidents: [DiagnosticIncident] = []
        var codes: [DiagnosticIncidentCode] { lock.withLock { incidents.map(\.code) } }
        func submit(_ incident: DiagnosticIncident) { lock.withLock { incidents.append(incident) } }
        func flush() {}
    }
}
