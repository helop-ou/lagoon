import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr account privacy", .serialized)
@MainActor
struct SeerrAccountPrivacyTests {
    @Test func switchingBeforeRestoreStartsCannotReconfigureTheSignedOutClient() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.select(fixture.a)
        await fixture.store.activate(for: nil)
        #expect(fixture.store.client.serverURL == nil)
        #expect(fixture.store.client.sessionCookie == nil)
        #expect(SeerrPrivacyProtocol.requests.isEmpty)
    }

    @Test func delayedAuthenticationCannotInstallACookieOrUserInTheNextAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.store.activate(for: fixture.a)
        SeerrPrivacyProtocol.hold("/api/v1/auth/jellyfin")
        let pending = Task { try await fixture.store.signIn(username: "A", password: "synthetic") }
        try await SeerrPrivacyProtocol.waitUntilHeld()
        await fixture.store.activate(for: fixture.b)
        #expect(fixture.store.user?.name == "B")
        SeerrPrivacyProtocol.releaseHeld()
        do {
            try await pending.value
            Issue.record("The outgoing authentication should have been invalidated")
        } catch is CancellationError {
        }
        #expect(fixture.store.user?.name == "B")
        #expect(fixture.store.client.sessionCookie == "cookie-b")
        #expect(fixture.credentials.string(for: fixture.cookieA) == "cookie-a")
        #expect(fixture.credentials.string(for: fixture.cookieB) == "cookie-b")
    }

    @Test func delayedDisconnectCannotClearTheNextAccountsSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.store.activate(for: fixture.a)
        SeerrPrivacyProtocol.hold("/api/v1/auth/logout")
        let pending = Task { await fixture.store.disconnect() }
        try await SeerrPrivacyProtocol.waitUntilHeld()
        #expect(fixture.store.client.sessionCookie == nil)
        #expect(fixture.store.user == nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) == nil)
        await fixture.store.activate(for: fixture.b)
        SeerrPrivacyProtocol.releaseHeld()
        await pending.value
        #expect(fixture.store.user?.name == "B")
        #expect(fixture.store.client.sessionCookie == "cookie-b")
        let logout = try #require(SeerrPrivacyProtocol.requests.first { $0.url?.path == "/api/v1/auth/logout" })
        #expect(logout.value(forHTTPHeaderField: "Cookie") == "connect.sid=cookie-a")
    }

    @Test func failedCookieDeletionIsNotRestoredByTheActualSessionStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.store.activate(for: fixture.a)
        fixture.credentials.failDeletion = true
        await fixture.store.disconnect()
        #expect(fixture.store.errorMessage != nil)
        #expect(fixture.credentials.string(for: fixture.cookieA) == "cookie-a")
        await fixture.store.activate(for: fixture.a)
        #expect(fixture.store.client.sessionCookie == nil)
        #expect(fixture.store.user == nil)
        #expect(fixture.store.errorMessage?.contains("could not be deleted") == true)
        await fixture.store.activate(for: fixture.b)
        #expect(fixture.store.user?.name == "B")
    }

    @Test func lateAutomaticSignInFailureCannotReplaceTheNextAccountsErrorState() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.store.activate(for: fixture.a)
        await fixture.store.disconnect()
        // Re-activation permits the automatic sign-in attempt again.
        await fixture.store.activate(for: fixture.a)
        let jellyfin = JellyfinClient(deviceId: "privacy", sessionConfiguration: fixture.configuration)
        jellyfin.configure(serverURL: fixture.a.serverURL)
        jellyfin.activateSession(token: "synthetic", userId: fixture.a.userId)
        SeerrPrivacyProtocol.hold("/QuickConnect/Enabled")
        let pending = Task { await fixture.store.signInUsingJellyfinIfNeeded(jellyfin) }
        try await SeerrPrivacyProtocol.waitUntilHeld()
        await fixture.store.activate(for: fixture.b)
        SeerrPrivacyProtocol.releaseHeld()
        await pending.value
        #expect(fixture.store.user?.name == "B")
        #expect(fixture.store.errorMessage == nil)
    }

    private final class Fixture {
        let suite = "SeerrAccountPrivacyTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let credentials = MemoryAccountCredentials()
        let configuration: URLSessionConfiguration
        let store: SeerrSessionStore
        let a = StoredAccount(serverURL: URL(string: "https://a.privacy.test")!, serverName: "A", userId: "same-user", userName: "A")
        let b = StoredAccount(serverURL: URL(string: "https://b.privacy.test")!, serverName: "B", userId: "same-user", userName: "B")
        let seerrURL = URL(string: "https://seerr.privacy.test")!
        var cookieA: String { AccountLocalData.seerrCookieKey(a, serverURL: seerrURL) }
        var cookieB: String { AccountLocalData.seerrCookieKey(b, serverURL: seerrURL) }
        init() throws {
            SeerrPrivacyProtocol.reset()
            defaults = UserDefaults(suiteName: suite)!
            configuration = .ephemeral
            configuration.protocolClasses = [SeerrPrivacyProtocol.self]
            store = SeerrSessionStore(client: SeerrClient(session: URLSession(configuration: configuration)), defaults: defaults,
                                      localData: AccountLocalData(defaults: defaults, credentials: credentials))
            defaults.set(seerrURL.absoluteString, forKey: AccountLocalData.seerrServerKey(a))
            defaults.set(seerrURL.absoluteString, forKey: AccountLocalData.seerrServerKey(b))
            try credentials.set("cookie-a", for: cookieA)
            try credentials.set("cookie-b", for: cookieB)
        }
        func cleanUp() {
            store.select(nil)
            SeerrPrivacyProtocol.releaseHeld()
            defaults.removePersistentDomain(forName: suite)
        }
    }
}

private nonisolated final class SeerrPrivacyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var heldPath: String?
    private nonisolated(unsafe) static var held: [SeerrPrivacyProtocol] = []
    private nonisolated(unsafe) static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func reset() { lock.withLock { recorded = []; heldPath = nil } }
    static func hold(_ path: String) { lock.withLock { heldPath = path } }
    static func waitUntilHeld() async throws {
        for _ in 0..<200 {
            if lock.withLock({ !held.isEmpty }) { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    static func releaseHeld() {
        let pending = lock.withLock { let result = held; held = []; heldPath = nil; return result }
        for item in pending { item.respond() }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let shouldHold = Self.lock.withLock {
            Self.recorded.append(request)
            if Self.heldPath == request.url?.path { Self.held.append(self); return true }
            return false
        }
        if !shouldHold { respond() }
    }
    override func stopLoading() {}
    private func respond() {
        guard let url = request.url else { return }
        var headers = ["Content-Type": "application/json"]
        let body: String
        switch url.path {
        case "/api/v1/status": body = #"{"version":"test"}"#
        case "/api/v1/settings/public": body = #"{"initialized":true,"mediaServerType":2}"#
        case "/api/v1/auth/me":
            let name = request.value(forHTTPHeaderField: "Cookie") == "connect.sid=cookie-b" ? "B" : "A"
            body = "{\"id\":7,\"username\":\"\(name)\",\"permissions\":32}"
        case "/api/v1/auth/jellyfin":
            headers["Set-Cookie"] = "connect.sid=late-a; Path=/; HttpOnly; Secure"
            body = #"{"id":8,"username":"Late A","permissions":32}"#
        case "/QuickConnect/Enabled": body = "false"
        default: body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
